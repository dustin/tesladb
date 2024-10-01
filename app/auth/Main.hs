module Main where

import           Options.Applicative (Parser, execParser, fullDesc, help, helper, info, long, progDesc, short,
                                      showDefault, strOption, switch, value, (<**>))
import           System.IO           (hFlush, stdout)

import           Tesla
import           Tesla.AuthDB

data Options = Options {
  optDBPath    :: String
  , optRefresh :: Bool
  }

options :: Parser Options
options = Options
  <$> strOption (long "dbpath" <> showDefault <> value "tesla.db" <> help "tesladb path")
  <*> switch (long "refresh" <> short 'r' <> help "refresh instead of asking for a token")

getToken :: IO String
getToken = putStr "Paste in a refresh token: " *> hFlush stdout *> getLine

login :: Options -> IO ()
login Options{..} = updateAuth optDBPath . AuthResponse "" 0 =<< getToken

refresh :: Options -> IO ()
refresh Options{..} = updateAuth optDBPath =<< refreshAuth =<< loadAuth optDBPath

run :: Options -> IO ()
run opts@Options{..}
  | optRefresh = refresh opts
  | otherwise = login opts

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Move stuff.")
