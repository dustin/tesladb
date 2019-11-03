{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.Async   (mapConcurrently_, race_)
import           Control.Concurrent.STM     (TChan, atomically, dupTChan,
                                             newBroadcastTChanIO, orElse,
                                             readTChan, readTVar, registerDelay,
                                             retry, writeTChan)
import           Control.Exception          (Exception, SomeException (..),
                                             bracket, catch, throw)
import           Control.Monad              (forever, guard, unless)
import           Data.Aeson                 (decode, encode)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromJust, isJust)
import           Data.Text                  (Text, breakOnEnd, unpack)
import qualified Data.Text.Encoding         as TE
import           Database.SQLite.Simple     hiding (bind, close)
import           Network.MQTT.Client
import           Network.URI
import           Options.Applicative        (Parser, execParser, fullDesc, help,
                                             helper, info, long, maybeReader,
                                             option, progDesc, short,
                                             showDefault, strOption, switch,
                                             value, (<**>))
import           System.Exit                (die)
import           System.Log.Logger          (Priority (DEBUG, INFO), debugM,
                                             errorM, infoM, rootLoggerName,
                                             setLevel, updateGlobalLogger)
import           System.Timeout             (timeout)

import           AuthDB
import           Tesla
import           TeslaDB

data Options = Options {
  optDBPath      :: String
  , optVName     :: Text
  , optNoMQTT    :: Bool
  , optVerbose   :: Bool
  , optMQTTURI   :: URI
  , optMQTTTopic :: Text
  , optInTopic   :: Text
  }

options :: Parser Options
options = Options
  <$> strOption (long "dbpath" <> showDefault <> value "tesla.db" <> help "tesladb path")
  <*> strOption (long "vname" <> showDefault <> value "my car" <> help "name of vehicle to watch")
  <*> switch (long "disable-mqtt" <> help "disable MQTT support")
  <*> switch (short 'v' <> long "verbose" <> help "enable debug logging")
  <*> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> strOption (long "mqtt-topic" <> showDefault <> value "tmp/tesla" <> help "MQTT topic")
  <*> strOption (long "listen-topic" <> showDefault <> value "tmp/tesla/in/#" <> help "MQTT listen topics for syncing")

type Sink = Options -> TChan VehicleData -> IO ()

excLoop :: String -> Sink -> Options -> TChan VehicleData  -> IO ()
excLoop n s opts ch = forever $ catch (s opts ch) handler

  where
    handler :: SomeException -> IO ()
    handler e = do
      errorM rootLoggerName $ mconcat ["Caught exception in handler: ", n, " - ", show e, " retrying shortly"]
      threadDelay 5000000

watchdogSink :: Sink
watchdogSink o ch = do
  tov <- registerDelay (3*600000000)
  again <- atomically $ (True <$ readTChan ch) `orElse` checkTimeout tov
  unless again $ die "Watchdog timeout"
  watchdogSink o ch

    where
      checkTimeout v = do
        v' <- readTVar v
        unless v' retry
        pure False

dbSink :: Sink
dbSink Options{..} ch = withConnection optDBPath storeThings

  where
    storeThings db = do
      dbInit db

      forever $ atomically (readTChan ch) >>= insertVData db

data DisconnectedException = DisconnectedException deriving Show

instance Exception DisconnectedException

blToText :: BL.ByteString -> Text
blToText = TE.decodeUtf8 . BL.toStrict

mqttSink :: Sink
mqttSink Options{..} ch = withConnection optDBPath (\db -> (withMQTT db) store)

  where
    withMQTT db = bracket (connect db) disco

    connect db = do
      infoM rootLoggerName $ mconcat ["Connecting to ", show optMQTTURI]
      mc <- connectURI mqttConfig{_protocol=Protocol50,
                                  _msgCB=SimpleCallback (tdbAPI db)} optMQTTURI
      props <- svrProps mc
      infoM rootLoggerName $ mconcat ["MQTT conn props from ", show optMQTTURI, ": ", show props]
      subr <- subscribe mc [(optInTopic, subOptions{_subQoS=QoS2})] mempty
      infoM rootLoggerName $ mconcat ["MQTT sub response: ", show subr]
      pure mc

    disco c = do
      errorM rootLoggerName ("disconnecting from " <> show optMQTTURI)
      normalDisconnect c
      infoM rootLoggerName ("disconnected from " <> show optMQTTURI)

    store mc = forever $ do
      vdata <- atomically $ do
        connd <- isConnectedSTM mc
        unless connd $ throw DisconnectedException
        readTChan ch
      debugM rootLoggerName "Delivering vdata via MQTT"
      publishq mc optMQTTTopic vdata True QoS2 [PropMessageExpiryInterval 900,
                                                PropContentType "application/json"]
      debugM rootLoggerName "Delivered vdata via MQTT"

    tdbAPI db mc t m props = call ((snd . breakOnEnd "/") t) ret m

      where
        ret = blToText . foldr f "" $ props
          where f (PropResponseTopic r) _ = r
                f _                     o = o

        rprops = filter f props
          where
            f (PropCorrelationData{}) = True
            f (PropUserProperty{})    = True
            f _                       = False

        call p "" _ = infoM rootLoggerName $ mconcat ["request to ", show p, " with no response topic"]

        call "days" res _ = do
          infoM rootLoggerName $ mconcat ["Days call responding to ", show res]
          days <- listDays db
          publishq mc res (encode . Map.fromList $ days) False QoS2 ([PropContentType "application/json"] <> rprops)

        call "day" res d = do
          infoM rootLoggerName $ mconcat ["Day call for ", show d, " responding to ", show res]
          days <- listDay db (BC.unpack d)
          publishq mc res (encode days) False QoS2 ([PropContentType "application/json"] <> rprops)

        call "fetch" res tss = do
          infoM rootLoggerName $ mconcat ["Fetch call for ", show tss, " responding to ", show res]
          let mts = decode ("\"" <> tss <> "\"")
          guard $ isJust mts
          vdata <- fetchDatum db (fromJust mts)
          publishq mc res vdata False QoS2 ([PropContentType "application/json"] <> rprops)

        call x _ _ = infoM rootLoggerName $ mconcat ["Call to invalid path: ", show x]

gather :: Options -> TChan  VehicleData -> IO ()
gather Options{..} ch = do
  vids <- vehicles =<< toke
  let vid = vids Map.! optVName
  infoM rootLoggerName $ mconcat ["Looping with vid: ", show vid]

  forever $ do
    debugM rootLoggerName "Fetching"
    vdata <- toke >>= \ai -> timeout 10000000 $ vehicleData ai (unpack vid)
    nt <- process vid vdata
    threadDelay nt

  where
    naptime :: VehicleData -> Int
    naptime vdata
          | isUserPresent vdata = 60000000
          | isCharging vdata    = 300000000
          | otherwise           = 600000000

    process :: Text -> Maybe VehicleData -> IO Int
    process _ Nothing = errorM rootLoggerName "Timed out, retrying in 60s" >> pure 60000000
    process vid (Just vdata) = do
      infoM rootLoggerName $ mconcat ["Fetched data for vid: ", show vid]
      atomically $ writeTChan ch vdata
      let nt = naptime vdata
      infoM rootLoggerName $ mconcat ["Sleeping for ", show nt,
                                      " user present: ", show $ isUserPresent vdata,
                                      ", charging: ", show $ isCharging vdata]
      pure $ naptime vdata

    toke :: IO AuthInfo
    toke = loadAuth optDBPath >>= \AuthResponse{..} -> pure $ fromToken _access_token

run :: Options -> IO ()
run opts@Options{optNoMQTT, optVerbose} = do
  updateGlobalLogger rootLoggerName (setLevel $ if optVerbose then DEBUG else INFO)

  tch <- newBroadcastTChanIO
  let sinks = [dbSink, watchdogSink] <> if optNoMQTT then [] else [excLoop "mqtt" mqttSink]
  race_ (gather opts tch) (mapConcurrently_ (\f -> f opts =<< d tch) sinks)

  where d ch = atomically $ dupTChan ch

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Move stuff.")
