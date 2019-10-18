{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Concurrent       (threadDelay)
import           Control.Concurrent.Async (mapConcurrently_, race_)
import           Control.Concurrent.STM   (TChan, atomically, dupTChan,
                                           newBroadcastTChanIO, readTChan,
                                           writeTChan)
import           Control.Exception        (SomeException (..), bracket, catch)
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
                                           strOption, switch, value, (<**>))
import           System.Log.Logger        (Priority (INFO), errorM, infoM,
                                           rootLoggerName, setLevel,
                                           updateGlobalLogger)

import           AuthDB
import           Tesla

data Options = Options {
  optDBPath      :: String
  , optVName     :: Text
  , optNoMQTT    :: Bool
  , optMQTTURI   :: URI
  , optMQTTTopic :: Text
  }

options :: Parser Options
options = Options
  <$> strOption (long "dbpath" <> showDefault <> value "tesla.db" <> help "tesladb path")
  <*> strOption (long "vname" <> showDefault <> value "my car" <> help "name of vehicle to watch")
  <*> switch (long "disable-mqtt" <> help "disable MQTT support")
  <*> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> strOption (long "mqtt-topic" <> showDefault <> value "tmp/tesla" <> help "MQTT topic")

createStatement :: Query
createStatement = "create table if not exists data (ts timestamp, data blob)"

insertStatement :: Query
insertStatement = "insert into data(ts, data) values(current_timestamp, ?)"

type Sink = Options -> TChan VehicleData -> IO ()

retry :: String -> Sink -> Options -> TChan VehicleData  -> IO ()
retry n s opts ch = forever $ do
  catch (s opts ch) handler

  where
    handler :: SomeException -> IO ()
    handler e = do
      errorM rootLoggerName $ mconcat ["Caught exception in handler: ", n, " - ", show e, " retrying shortly"]
      threadDelay 5000000


dbSink :: Sink
dbSink Options{..} ch = do
  withConnection optDBPath storeThings

  where
    storeThings db = do
      execute_ db "pragma auto_vacuum = incremental"
      execute_ db createStatement

      forever $ do
        vdata <- atomically $ readTChan ch
        execute db insertStatement (Only vdata)

mqttSink :: Sink
mqttSink Options{..} ch = do
  withMQTT store

  where
    withMQTT = bracket connect normalDisconnect

    connect = do
      mc <- connectURI mqttConfig{_protocol=Protocol50} optMQTTURI
      props <- svrProps mc
      infoM rootLoggerName $ mconcat ["MQTT conn props from ", show optMQTTURI, ": ", show props]
      pure mc

    store mc = forever $ do
      vdata <- atomically $ readTChan ch
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
run opts@Options{optNoMQTT} = do
  tch <- newBroadcastTChanIO
  let sinks = [dbSink] <> if optNoMQTT then [] else [retry "mqtt" mqttSink]
  race_ (gather opts tch) (mapConcurrently_ (\f -> f opts =<< d tch) sinks)

  where d ch = atomically $ dupTChan ch

main :: IO ()
main = do
  updateGlobalLogger rootLoggerName (setLevel INFO)
  run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Move stuff.")
