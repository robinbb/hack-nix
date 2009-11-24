module Main where
import Control.Monad.Reader.Class
import Data.Function
import Text.PrettyPrint
import qualified Data.Map as M
import qualified Data.ByteString.Lazy as B
import qualified Data.ByteString.Lazy.Char8 as BL
import Distribution.Package
import Distribution.Simple.Utils (findPackageDesc)
import Distribution.PackageDescription
import Config
import Control.Exception
import Nix
import NixLangUtil
import NixLanguage
import Index
import Data.Maybe
import Control.Monad
import Control.Monad.Trans
import System.Exit
import System.Directory
import System.Environment
import Network.URI
import Data.List
import Utils
import Patching
import BuildEnvs
import System.Process
import System.IO


-- writeConfig Map file = writeFile file $ lines $ mapWithKey

-- [>minimal Config 
-- parseConfig :: String -> Map
-- parseConfig =
--   let split s = let  (a,_:set) (break ( == '=') in (a,set)
--   in fromList . map split . lines

-- determine list of packages to be installed based on TargetPackages setting
filterTargetPackages :: M.Map PackageName [Dependency] -> [GenericPackageDescription] -> ConfigR [GenericPackageDescription]
filterTargetPackages preferred packages = do
  tp <- asks targetPackages
  let 
      sortByVersion :: [GenericPackageDescription] -> [GenericPackageDescription]
      sortByVersion = sortBy ( (flip compare) `on` (pkgVersion . package . packageDescription) )
      byName :: M.Map PackageName [GenericPackageDescription]      
      byName = M.map sortByVersion $ M.fromListWith (++) [ let name = (pkgName . package . packageDescription) p in (name, [p]) | p <- packages ]
  -- after grouping all packages by name only keep wanted packages
  return $ concatMap (filterByName tp) $ M.toList byName
  where
    -- match packages which has been selected by the user explicitly 
    elected :: [Dependency] -> [ GenericPackageDescription ] -> [GenericPackageDescription]
    elected deps pkgs = concat [ filter (matchDepndencyConstraints d . package . packageDescription ) pkgs | d <- deps ]

    filterByName :: TargetPackages Dependency -> (PackageName, [GenericPackageDescription]) -> [GenericPackageDescription]
    filterByName tp (pn@(PackageName name), ps) = case tp of
      TPAll -> ps
      TPMostRecentPreferred deps -> nub $ head ps : elected deps ps ++ elected (fromMaybe [] (M.lookup pn preferred)) ps
      TPCustom deps -> nub $ elected deps ps


  

runWithConfig :: String -> [String] -> IO ()
runWithConfig cfg args =  do
  cfg <- liftM parseConfig $ readFile cfg
  withConfig cfg $ do
    case args of
      [] -> updateHackageIndexFile
      ["--unpack", fullName] -> unpackPackage fullName
      ["--create-patch", fullName] -> createPatch fullName
      ["--patch-workflow", fullName] -> patchWorkflow fullName updateHackageIndexFile
      ["--to-nix"] -> packageToNix >> return ()
      ["--write-hack-nix-cabal-config"] -> writeHackNixCabalConfig
      ["--build-env", name] -> buildEnv name
      _ -> liftIO $ help >> exitWith (ExitFailure 1)

updateHackageIndexFile :: ConfigR ()
updateHackageIndexFile = do
    cfg <- ask
    (hackageIndex, _) <- liftIO $ downloadCached (hackageIndex cfg) False
    liftIO $ putStrLn $ "hackage index is " ++ hackageIndex
    parsedTestCabals <- liftIO $ mapM parsePkgFormFile $ testCabals cfg
    pd <- asks patchDirectory
    indexContents <- liftIO $ liftM (readIndex pd) $ BL.readFile hackageIndex

    -- liftIO $ do
    --   print "parsed test cabals"
    --   print parsedTestCabals

    let allPkgs = packages indexContents ++ parsedTestCabals

    -- liftIO $ writeFile "all" (show (packages indexContents))
    -- let (pkgs :: [ GenericPackageDescription ]) = packages indexContents
    targetPackages <- filterTargetPackages (preferredVersions indexContents ) $ allPkgs
    
    -- liftIO $ print indexContents
    attrs <- liftIO $ mapM (\(nr,b) -> do
                let (PackageName name) = pkgName $ package $ packageDescription $ b
                putStrLn $ "checking source of " ++ name  ++ "  " ++ show nr ++ "/" ++ (show . length ) allPkgs
                packageDescriptionToNix (if b `elem` parsedTestCabals then STNone else STHackage) b) $ zip [1 ..] $ targetPackages
    let result = unlines $ "["
                           : (map (renderStyle style . toDoc) attrs)
                           ++ ["]"]

    liftIO $ do
      -- STDOUT 
      -- putStrLn result
      case targetFile cfg of 
        Just f -> writeFile f result
        Nothing -> return ()

main = (flip finally) saveNixCache $ do
  loadNixCache
  dcp <- defaultConfigPath
  args <- getArgs
  case args of
    ["--patch-workflow"] -> writeSampleConfig dcp
    ["--write-config"] -> writeSampleConfig dcp
    ["--write-config", cfg] -> writeSampleConfig cfg
    ["--print-format-info"] -> putStrLn $ formatInfo
    ["-h"] -> help
    ["--help"] -> help
    ("--config":cfg:args) -> do runWithConfig cfg args
    args -> do
      de <- doesFileExist dcp
      case de of
        True -> runWithConfig dcp args
        False -> do  putStrLn $ "sample config does not exist, writing it to " ++ dcp
                     putStrLn "adjust it to your needs and rerun .."
                     writeSampleConfig dcp
                     putStrLn "done, also see --help"
                     exitWith (ExitFailure 1)

help :: IO ()
help = do
    dcp <- defaultConfigPath
    progName <- getProgName
    putStrLn $ unlines $ map ("  " ++ ) $
          [ progName ++ ": get index from hackage making its contents readable by nix"
          , ""
          , ""
          , progName ++ " [cfg] dest         : create nix expressions and put them into dest"
          , ""
          , progName ++ "--print-format-info : prints format info about config"
          , progName ++ "--write-config [cfg]: writes an initial config file"
          , "default config path is: " ++ dcp
          , ""
          , "  writing patches: "
          , "  ================ "
          , "--unpack           full-name : unpacks source into working directory"
          , "--create-patch     full-name : create patch in target destination (haskell-nix-overlay)"
          , "all:"
          , "--patch-workflow   full-name : unpack, apply patch, start $SHELL, create patch, run git add and git commit"
          , "--to-nix           convert .cabal file in current directory into .nix format, put it into .dist/full-name.nix"
          , "                   so that you can import it easily and append it to the list of hackage packages"
          , "                   also run ./setup dist to create current dist file"
          , ""
          , "  creating environments to build cabal package "
          , "  ============================================ "
          , " --write-hack-nix-cabal-config: Writes a .hack-nix-cabal-config sample file"
          , "                                containing all variations of flags"
          , " --build-env name             : build one of those envs"
          ]

