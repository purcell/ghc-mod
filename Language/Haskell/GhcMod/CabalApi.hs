{-# LANGUAGE OverloadedStrings #-}

module Language.Haskell.GhcMod.CabalApi (
    fromCabalFile
  , cabalParseFile
  , cabalBuildInfo
  , cabalAllDependPackages
  , cabalAllSourceDirs
  , getGHCVersion
  ) where

import Control.Applicative
import Control.Exception (throwIO)
import Data.List (intercalate)
import Data.Maybe (maybeToList, listToMaybe)
import Data.Set (fromList, toList)
import Distribution.Package (Dependency(Dependency), PackageName(PackageName))
import Distribution.PackageDescription
import Distribution.PackageDescription.Parse (readPackageDescription)
import Distribution.Simple.Program (ghcProgram)
import Distribution.Simple.Program.Types (programName, programFindVersion)
import Distribution.Text (display)
import Distribution.Verbosity (silent)
import Distribution.Version (versionBranch)
import Language.Haskell.GhcMod.Types
import System.FilePath

----------------------------------------------------------------

fromCabalFile :: [GHCOption]
              -> Cradle
              -> IO ([GHCOption],[IncludeDir],[Package])
fromCabalFile ghcOptions cradle = do
    cabal <- cabalParseFile cfile
    case cabalBuildInfo cabal of
        Nothing    -> throwIO $ userError "cabal file is broken"
        Just binfo -> return $ cookInfo ghcOptions cradle cabal binfo
  where
    Just cfile = cradleCabalFile cradle

cookInfo :: [String] -> Cradle -> GenericPackageDescription -> BuildInfo
         -> ([GHCOption],[IncludeDir],[Package])
cookInfo ghcOptions cradle cabal binfo = (gopts,idirs,depPkgs)
  where
    wdir       = cradleCurrentDir cradle
    Just cdir  = cradleCabalDir   cradle
    Just cfile = cradleCabalFile  cradle
    gopts      = getGHCOptions ghcOptions binfo
    idirs      = includeDirectories cdir wdir $ cabalAllSourceDirs cabal
    depPkgs    = removeMe cfile $ cabalAllDependPackages cabal

removeMe :: FilePath -> [String] -> [String]
removeMe cabalfile = filter (/= me)
  where
    me = dropExtension $ takeFileName cabalfile

----------------------------------------------------------------

cabalParseFile :: FilePath -> IO GenericPackageDescription
cabalParseFile = readPackageDescription silent

----------------------------------------------------------------

getGHCOptions :: [String] -> BuildInfo -> [String]
getGHCOptions ghcOptions binfo = ghcOptions ++ exts ++ [lang] ++ libs ++ libDirs
  where
    exts = map (("-X" ++) . display) $ usedExtensions binfo
    lang = maybe "-XHaskell98" (("-X" ++) . display) $ defaultLanguage binfo
    libs = map ("-l" ++) $ extraLibs binfo
    libDirs = map ("-L" ++) $ extraLibDirs binfo

----------------------------------------------------------------

-- Causes error, catched in the upper function.
cabalBuildInfo :: GenericPackageDescription -> Maybe BuildInfo
cabalBuildInfo pd = fromLibrary pd <|> fromExecutable pd
  where
    fromLibrary c    = libBuildInfo . condTreeData <$> condLibrary c
    fromExecutable c = buildInfo . condTreeData . snd <$> listToMaybe (condExecutables c)

----------------------------------------------------------------

cabalAllSourceDirs :: GenericPackageDescription -> [FilePath]
cabalAllSourceDirs = fromPackageDescription (f libBuildInfo) (f buildInfo) (f testBuildInfo) (f benchmarkBuildInfo)
  where
    f getBuildInfo = concatMap (hsSourceDirs . getBuildInfo . condTreeData)

cabalAllDependPackages :: GenericPackageDescription -> [Package]
cabalAllDependPackages pd = uniqueAndSort pkgs
  where
    pkgs = map getDependencyPackageName $ cabalAllDependency pd

cabalAllDependency :: GenericPackageDescription -> [Dependency]
cabalAllDependency = fromPackageDescription getDeps getDeps getDeps getDeps
  where
    getDeps :: [Tree a] -> [Dependency]
    getDeps = concatMap condTreeConstraints

getDependencyPackageName :: Dependency -> Package
getDependencyPackageName (Dependency (PackageName nm) _) = nm

----------------------------------------------------------------

type Tree = CondTree ConfVar [Dependency]

fromPackageDescription :: ([Tree Library]    -> [a])
                       -> ([Tree Executable] -> [a])
                       -> ([Tree TestSuite]  -> [a])
                       -> ([Tree Benchmark]  -> [a])
                       -> GenericPackageDescription
                       -> [a]
fromPackageDescription f1 f2 f3 f4 pd = lib ++ exe ++ tests ++ bench
  where
    lib   = f1 . maybeToList . condLibrary $ pd
    exe   = f2 . map snd . condExecutables $ pd
    tests = f3 . map snd . condTestSuites  $ pd
    bench = f4 . map snd . condBenchmarks  $ pd

----------------------------------------------------------------

includeDirectories :: String -> String -> [FilePath] -> [String]
includeDirectories cdir wdir []   = uniqueAndSort [cdir,wdir]
includeDirectories cdir wdir dirs = uniqueAndSort (map (cdir </>) dirs ++ [cdir,wdir])

----------------------------------------------------------------

uniqueAndSort :: [String] -> [String]
uniqueAndSort = toList . fromList

----------------------------------------------------------------

-- | Getting GHC version. 7.6.3 becames 706 in the second of the result.
getGHCVersion :: IO (GHCVersion, Int)
getGHCVersion = ghcVer >>= toTupple
  where
    ghcVer = programFindVersion ghcProgram silent (programName ghcProgram)
    toTupple Nothing  = throwIO $ userError "ghc not found"
    toTupple (Just v)
      | length vs < 2 = return (verstr, 0)
      | otherwise     = return (verstr, ver)
      where
        vs = versionBranch v
        ver = (vs !! 0) * 100 + (vs !! 1)
        verstr = intercalate "." . map show $ vs
