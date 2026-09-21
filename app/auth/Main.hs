module Main where

import           Effectful           (Eff, IOE, liftIO, runEff, (:>))
import           Options.Applicative (Parser, execParser, fullDesc, help,
                                      helper, info, long, progDesc, short,
                                      showDefault, strOption, switch, value,
                                      (<**>))
import           System.IO           (hFlush, stdout)

import           Tesla
import           Tesla.DB
import           Tesla.RunDB

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

dispatch :: (IOE :> es, DB :> es) => Options -> Eff es ()
dispatch Options{optRefresh}
  | optRefresh = updateAuth =<< liftIO . refreshAuth =<< loadAuth
  | otherwise = updateAuth . AuthResponse "" 0 =<< liftIO getToken

run :: Options -> IO ()
run opts@Options{optDBPath} =
  runEff . withDB optDBPath $ do
    initDB
    dispatch opts

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Move stuff.")
