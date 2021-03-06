-----------------------------------------------------------------------------
--
-- Module      :  Main
-- Copyright   :  (c) Phil Freeman 2013
-- License     :  MIT
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------

{-# LANGUAGE DataKinds, GeneralizedNewtypeDeriving, TupleSections, RecordWildCards #-}

module Main where

import Control.Applicative
import Control.Monad.Error

import Data.Maybe (fromMaybe)
import Data.Version (showVersion)

import Options.Applicative as Opts
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)
import System.Exit (exitSuccess, exitFailure)
import System.IO (hPutStr, hPutStrLn, stderr)

import qualified Language.PureScript as P
import qualified Paths_purescript as Paths


data PSCOptions = PSCOptions
  { pscInput     :: [FilePath]
  , pscOpts      :: P.Options P.Compile
  , pscStdIn     :: Bool
  , pscOutput    :: Maybe FilePath
  , pscExterns   :: Maybe FilePath
  , pscUsePrefix :: Bool
  }

data InputOptions = InputOptions
  { ioNoPrelude   :: Bool
  , ioUseStdIn    :: Bool
  , ioInputFiles  :: [FilePath]
  }

readInput :: InputOptions -> IO [(Maybe FilePath, String)]
readInput InputOptions{..}
  | ioUseStdIn = return . (Nothing ,) <$> getContents
  | otherwise = do content <- forM ioInputFiles $ \inFile -> (Just inFile, ) <$> readFile inFile
                   return (if ioNoPrelude then content else (Nothing, P.prelude) : content)

compile :: PSCOptions -> IO ()
compile (PSCOptions input opts stdin output externs usePrefix) = do
  modules <- P.parseModulesFromFiles (fromMaybe "") <$> readInput (InputOptions (P.optionsNoPrelude opts) stdin input)
  case modules of
    Left err -> do
      hPutStr stderr $ show err
      exitFailure
    Right ms -> do
      case P.compile opts (map snd ms) prefix of
        Left err -> do
          hPutStrLn stderr err
          exitFailure
        Right (js, exts, _) -> do
          case output of
            Just path -> mkdirp path >> writeFile path js
            Nothing -> putStrLn js
          case externs of
            Just path -> mkdirp path >> writeFile path exts
            Nothing -> return ()
          exitSuccess
  where
  prefix = if usePrefix
              then ["Generated by psc version " ++ showVersion Paths.version]
              else []

mkdirp :: FilePath -> IO ()
mkdirp = createDirectoryIfMissing True . takeDirectory

codeGenModule :: Parser String
codeGenModule = strOption $
     long "codegen"
  <> help "A list of modules for which Javascript and externs should be generated. This argument can be used multiple times."

dceModule :: Parser String
dceModule = strOption $
     short 'm'
  <> long "module"
  <> help "Enables dead code elimination, all code which is not a transitive dependency of a specified module will be removed. This argument can be used multiple times."

browserNamespace :: Parser String
browserNamespace = strOption $
     long "browser-namespace"
  <> Opts.value "PS"
  <> showDefault
  <> help "Specify the namespace that PureScript modules will be exported to when running in the browser."

verboseErrors :: Parser Bool
verboseErrors = switch $
     short 'v'
  <> long "verbose-errors"
  <> help "Display verbose error messages"

noOpts :: Parser Bool
noOpts = switch $
     long "no-opts"
  <> help "Skip the optimization phase."

runMain :: Parser (Maybe String)
runMain = optional $ noArgs <|> withArgs
  where
  defaultVal = "Main"
  noArgs     = flag' defaultVal (long "main")
  withArgs   = strOption $
        long "main"
     <> help (concat [
            "Generate code to run the main method in the specified module. ",
            "(no argument: \"", defaultVal, "\")"
        ])

noMagicDo :: Parser Bool
noMagicDo = switch $
     long "no-magic-do"
  <> help "Disable the optimization that overloads the do keyword to generate efficient code specifically for the Eff monad."

noTco :: Parser Bool
noTco = switch $
     long "no-tco"
  <> help "Disable tail call optimizations"

noPrelude :: Parser Bool
noPrelude = switch $
     long "no-prelude"
  <> help "Omit the Prelude"

useStdIn :: Parser Bool
useStdIn = switch $
     short 's'
  <> long "stdin"
  <> help "Read from standard input"

inputFile :: Parser FilePath
inputFile = strArgument $
     metavar "FILE"
  <> help "The input .purs file(s)"

outputFile :: Parser (Maybe FilePath)
outputFile = optional . strOption $
     short 'o'
  <> long "output"
  <> help "The output .js file"

externsFile :: Parser (Maybe FilePath)
externsFile = optional . strOption $
     short 'e'
  <> long "externs"
  <> help "The output .e.purs file"

noPrefix :: Parser Bool
noPrefix = switch $
     short 'p'
  <> long "no-prefix"
  <> help "Do not include comment header"

options :: Parser (P.Options P.Compile)
options = P.Options <$> noPrelude
                    <*> noTco
                    <*> noMagicDo
                    <*> runMain
                    <*> noOpts
                    <*> verboseErrors
                    <*> additionalOptions
  where
  additionalOptions =
    P.CompileOptions <$> browserNamespace
                     <*> many dceModule
                     <*> many codeGenModule

pscOptions :: Parser PSCOptions
pscOptions = PSCOptions <$> many inputFile
                        <*> options
                        <*> useStdIn
                        <*> outputFile
                        <*> externsFile
                        <*> (not <$> noPrefix)

main :: IO ()
main = execParser opts >>= compile
  where
  opts        = info (version <*> helper <*> pscOptions) infoModList
  infoModList = fullDesc <> headerInfo <> footerInfo
  headerInfo  = header   "psc - Compiles PureScript to Javascript"
  footerInfo  = footer $ "psc " ++ showVersion Paths.version

  version :: Parser (a -> a)
  version = abortOption (InfoMsg (showVersion Paths.version)) $ long "version" <> help "Show the version number" <> hidden

