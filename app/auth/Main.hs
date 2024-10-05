module Main where

import           Cleff
import           Options.Applicative (Parser, execParser, fullDesc, help, helper, info, long, progDesc, short,
                                      showDefault, strOption, switch, value, (<**>))
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

login :: [IOE, DB] :>> es => Eff es ()
login = updateAuth . AuthResponse "" 0 =<< liftIO getToken

refresh :: [IOE, DB] :>> es => Eff es ()
refresh = updateAuth =<< liftIO . refreshAuth =<< loadAuth

dispatch :: [IOE, DB] :>> es => Options -> Eff es ()
dispatch Options{optRefresh}
  | optRefresh = refresh
  | otherwise = login

run :: Options -> IO ()
run opts@Options{optDBPath} = do
  runIOE . withDB optDBPath $ do
    initDB
    dispatch opts

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Move stuff.")
