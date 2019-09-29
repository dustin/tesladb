{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Concurrent       (threadDelay)
import           Control.Concurrent.Async (mapConcurrently_)
import           Control.Concurrent.STM   (TChan, atomically, dupTChan,
                                           newBroadcastTChanIO, readTChan,
                                           writeTChan)
import           Control.Monad            (forever)
import qualified Data.Map.Strict          as Map
import           Data.Maybe               (fromJust)
import           Data.Text                (Text, unpack)
import           Database.SQLite.Simple   hiding (bind, close)
import           Network.MQTT.Client
import           Network.URI
import           Options.Applicative      (Parser, execParser, fullDesc, help,
                                           helper, info, long, maybeReader,
                                           option, progDesc, showDefault,
                                           strOption, value, (<**>))
import           System.Log.Logger        (Priority (INFO), infoM,
                                           rootLoggerName, setLevel,
                                           updateGlobalLogger)

import           AuthDB
import           Tesla

data Options = Options {
  optDBPath      :: String
  , optVName     :: Text
  , optMQTTURI   :: URI
  , optMQTTTopic :: Text
  }

options :: Parser Options
options = Options
  <$> strOption (long "dbpath" <> showDefault <> value "tesla.db" <> help "tesladb path")
  <*> strOption (long "vname" <> showDefault <> value "my car" <> help "name of vehicle to watch")
  <*> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> strOption (long "mqtt-topic" <> showDefault <> value "tmp/tesla" <> help "MQTT topic")

createStatement :: Query
createStatement = "create table if not exists data (ts timestamp, data blob)"

insertStatement :: Query
insertStatement = "insert into data(ts, data) values(current_timestamp, ?)"

dbSink :: Options -> TChan VehicleData -> IO ()
dbSink Options{..} ch = do
  rch <- atomically $ dupTChan ch
  db <- open optDBPath
  execute_ db "pragma auto_vacuum = incremental"
  execute_ db createStatement

  forever $ do
    vdata <- atomically $ readTChan rch
    execute db insertStatement (Only vdata)

mqttSink :: Options -> TChan VehicleData -> IO ()
mqttSink Options{..} ch = do
  rch <- atomically $ dupTChan ch
  mc <- connectURI mqttConfig{_protocol=Protocol50} optMQTTURI
  props <- svrProps mc
  infoM rootLoggerName $ mconcat ["MQTT conn props from ", show optMQTTURI, ": ", show props]

  forever $ do
    vdata <- atomically $ readTChan rch
    publishq mc optMQTTTopic vdata True QoS2 [PropMessageExpiryInterval 900,
                                              PropContentType "application/json"]
gather :: Options -> TChan  VehicleData -> IO ()
gather Options{..} ch = do
  vids <- vehicles =<< toke
  let vid = vids Map.! optVName
  infoM rootLoggerName $ mconcat ["Looping with vid: ", show vid]

  forever $ do
    vdata <- toke >>= \ai -> vehicleData ai (unpack vid)
    infoM rootLoggerName $ mconcat ["Fetched data for vid: ", show vid]
    atomically $ writeTChan ch vdata
    let nt = naptime vdata
    infoM rootLoggerName $ mconcat ["Sleeping for ", show nt,
                                    " user present: ", show $ isUserPresent vdata,
                                    ", charging: ", show $ isCharging vdata]
    threadDelay nt

  where naptime vdata
          | isUserPresent vdata = 60000000
          | isCharging vdata    = 300000000
          | otherwise           = 600000000

        toke :: IO AuthInfo
        toke = loadAuth optDBPath >>= \AuthResponse{..} -> pure $ fromToken _access_token

run :: Options -> IO ()
run opts = do
  tch <- newBroadcastTChanIO

  mapConcurrently_ (\f -> f opts tch) [gather, dbSink, mqttSink]

main :: IO ()
main = do
  updateGlobalLogger rootLoggerName (setLevel INFO)
  run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Move stuff.")
