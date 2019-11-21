{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Exception   (bracket_)
import           Options.Applicative (Parser, execParser, fullDesc, help,
                                      helper, info, long, progDesc, short,
                                      showDefault, strOption, switch, value,
                                      (<**>))
import           System.IO           (hFlush, hGetEcho, hSetEcho, stdin, stdout)
import           Tesla
import           Tesla.AuthDB

data Options = Options {
  optDBPath    :: String
  , optAccess  :: String
  , optSecret  :: String
  , optEmail   :: String
  , optRefresh :: Bool
  }

options :: Parser Options
options = Options
  <$> strOption (long "dbpath" <> showDefault <> value "tesla.db" <> help "tesladb path")
  <*> strOption (long "access_key" <> value "81527cff06843c8634fdc09e8ac0abefb46ac849f38fe1e431c2ef2106796384" <> help "access key")
  <*> strOption (long "access_secret" <> value "c7257eb71a564034f9419ee651c7d0e5f7aa6bfbd18bafb5c5c033b093bb2fa3" <> help "access secret")
  <*> strOption (long "email" <> value "" <> help "email address")
  <*> switch (long "refresh" <> short 'r' <> help "refresh instead of login")

withEcho :: Bool -> IO a -> IO a
withEcho echo action = do
  putStr "Enter password: " >> hFlush stdout
  old <- hGetEcho stdin
  bracket_ (hSetEcho stdin echo) (hSetEcho stdin old) action

getPass :: IO String
getPass = withEcho False getLine

login :: Options -> IO ()
login Options{..} = do
  pw <- getPass
  let ai = AuthInfo{_bearerToken="", _clientID=optAccess, _clientSecret=optSecret, _email=optEmail, _password=pw}
  ar <- authenticate ai
  updateAuth optDBPath ar

refresh :: Options -> IO ()
refresh Options{..} = do
  ar <- loadAuth optDBPath
  let ai = AuthInfo{_bearerToken="", _clientID=optAccess, _clientSecret=optSecret, _email=optEmail, _password=""}
  ar' <- refreshAuth ai ar
  updateAuth optDBPath ar'

run :: Options -> IO ()
run opts@Options{..}
  | optRefresh = refresh opts
  | otherwise = login opts

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Move stuff.")
