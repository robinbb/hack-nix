module BuildEnvs where
import Control.Monad.Reader.Class
import System.FilePath
import Text.PrettyPrint
import NixLangUtil
import NixLanguage
import Data.List
import System.Process
import System.Directory
import System.Exit
import Control.Monad
import Utils
import Config
import Control.Monad.Trans
import System.IO
import Distribution.PackageDescription
import Distribution.Package

writeHackNixCabalConfig :: ConfigR ()
writeHackNixCabalConfig = do
  -- never overwrite a config. Append instead 
  h <- liftIO $ openFile hackNixCabalConfig AppendMode

  -- first is default 
  pd <- parseCabalFileCurrentDir

  let flags = [ (flagName, flagDefault)
             | (MkFlag (FlagName flagName) flagDescription flagDefault flagManual) <- genPackageFlags pd
             ]
  liftIO $ print flags

  -- calculate all flag combinations 
  let combinations =
        foldr (\n e -> e >>= n) [[]] [ (\l -> [ (name, def):l, (name, not def):l ]) | (name, def) <- flags ]

  liftIO $ print combinations
  let names = "default":(map ( ("way" ++ ) . show) [2..])
  let header = "# generated lines:\n"
  liftIO $ hPutStrLn h $
      if null combinations then
        header ++ "default:\n"
      else header ++ (unlines $ zipWith (\n flags -> n ++ ":" ++ flagsToString flags) names combinations)

  where flagsToString list =
          intercalate " " [ (if value then "" else "-") ++ name | (name, value) <- list ]


-- runs ./[Ss]etup dist
-- and creates dist/name.nix 
packageToNix :: ConfigR FilePath
packageToNix = do
  pd <- parseCabalFileCurrentDir
  setupE <- findSetup
  (inH, outH, errH, p) <- liftIO $ runInteractiveProcess ("./"++setupE) ["sdist"] Nothing Nothing
  e <- liftIO $ liftM lines $ hGetContents outH
  ec <- liftIO $ waitForProcess p
  case ec of
    ExitFailure (ec) -> liftIO $ die $ "./[sS]etup sdist failed with exit code " ++ (show ec)
    ExitSuccess -> do
      pwd <- liftIO $ getCurrentDirectory
      let pref = "Source tarball created: "
      let distFile = drop (length pref) $ head $ filter (pref `isPrefixOf`) e
      nixT <- liftIO $ packageDescriptionToNix (STFile (pwd ++ "/" ++ distFile) ) $ pd
      let pD = packageDescription $ pd
      let (PackageIdentifier (PackageName name) version) = package pD
      let nixFile = "dist/" ++ name ++ ".nix"
      liftIO $ writeFile nixFile  (renderStyle style $ toDoc $ nixT)
      return nixFile


buildEnv :: String -> ConfigR ()
buildEnv envName = do
  let readFlag ('-':envName) = (envName, False)
      readFlag envName = (envName, True)
      rmComments =  (filter (not . ("#" `isPrefixOf`)))
      splitLine l = case break (== ':') l of
        (envName, (':':flags)) -> Right (envName, (map readFlag . words) flags)
        r -> Left r
        
  fc <- liftIO $ liftM ( rmComments . lines) $ readFile hackNixCabalConfig
  case filter ( (envName++":") `isPrefixOf`) fc of
    [] -> liftIO $ die $ unlines [
                 "configuration with envName " ++ envName ++ "not found in" ++ hackNixCabalConfig,
                 "I know about these names: " ++ show [ envName | Right (envName, _)  <- map splitLine fc ]
                ]
    (h:x:_) -> liftIO $ die $ "envName " ++ envName ++ " is defined multiple times"
    (h:_) -> do
      case  splitLine h of
        Left s -> liftIO $ die $ "can't read config line: " ++ h ++ " result : " ++ show s
        Right (envName, flags) -> do

          -- build dist file more important write .cabal file in a nix readable format: 
          thisPkgNixFile <- packageToNix

          let nixFilesDir = (hackNixEnvs </> "nix")
              nixFile = nixFilesDir </> envName ++ ".nix"
              thisPkgNixFile9 = nixFilesDir </> envName ++ "9.nix"

          liftIO $ createDirectoryIfMissing True nixFilesDir

          liftIO $ copyFile thisPkgNixFile thisPkgNixFile9

          -- make this package uniq by assigning version 99999 
          liftIO $ run (Just 0) "sed" [ "-i", "s@version = \"[^\"]*\";@version=\"99999\";@", thisPkgNixFile9] Nothing Nothing
          -- I should use regexp package or such - get the job done for now

          overlayRepo <- asks haskellNixOverlay
          
          pd <- parseCabalFileCurrentDir
          
          let PackageIdentifier (PackageName pName) version = package $ packageDescription pd
              flagsStr = intercalate " " [ n ++ " = " ++ (if set then "true" else "false") ++ "; " | (n, set) <- flags]

          -- I should do proper quoting etc - I'm too lazy 

          -- I'm too lazy to get all dependencies of this .cabal file as well. 
          -- so built cabal package from dist/full-name.nix and use its buildInputs and propagatedBuildInputs value
          liftIO $ writeFile nixFile $ unlines [
               "let nixOverlay = import \"" ++ overlayRepo ++ "\" {};",
               "    lib = nixOverlay.lib;",
               "    pkg = builtins.getAttr \"" ++ pName ++ "\" (nixOverlay.haskellOverlayPackagesFun.merge (args: args // {",
               "      targetPackages = [{ n = \"" ++ pName ++ "\"; v = \"99999\"; }];",
               "      packageFlags = lib.attrSingleton \"" ++ pName ++ "-99999\" { " ++ flagsStr ++ " };",
               "      packages = args.packages ++ [ (nixOverlay.libOverlay.pkgFromDb (import ./" ++ takeFileName thisPkgNixFile9 ++ ")) ];",
               "      debugS = true;",
               "    })).result;",
               "in { env = nixOverlay.envFromHaskellLibs (pkg.buildInputs ++ pkg.propagatedBuildInputs); }"
            ]
          
          liftIO $ do
            let envPath = (hackNixEnvs </> envName)
            run (Just 0) "nix-env" ["-p", envPath, "-iA", "env", "-f", nixFile, "--show-trace"] Nothing Nothing 
            putStrLn $ "success: Now source " ++ envPath ++ "/source-me/haskell-env"
