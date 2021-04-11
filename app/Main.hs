{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Concurrent.STM     (TChan, atomically, readTChan, writeTChan)
import           Control.Monad              (forever, guard, unless, void)
import           Control.Monad.Catch        (SomeException (..), bracket, catch, throwM)
import           Control.Monad.IO.Class     (MonadIO (..))
import           Control.Monad.IO.Unlift    (withRunInIO)
import           Control.Monad.Logger       (LoggingT)
import           Control.Monad.Reader       (asks)
import           Data.Aeson                 (decode, encode)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromJust, fromMaybe, isJust)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Database.SQLite.Simple     hiding (bind, close)
import           Network.MQTT.Client
import           Network.URI
import           Options.Applicative        (Parser, execParser, fullDesc, help, helper, info, long, maybeReader,
                                             option, progDesc, short, showDefault, strOption, switch, value, (<**>))
import           Text.Read                  (readMaybe)
import           UnliftIO.Timeout           (timeout)

import           Tesla.AuthDB
import           Tesla.Car
import qualified Tesla.Car.Commands         as CMD
import           Tesla.DB
import           Tesla.Runner

data Options = Options {
  optDBPath        :: FilePath
  , optVName       :: Text
  , optNoMQTT      :: Bool
  , optVerbose     :: Bool
  , optMQTTURI     :: URI
  , optMQTTTopic   :: Text
  , optInTopic     :: Text
  , optCMDsEnabled :: Bool
  }

type VSink = Sink Options VehicleData

options :: Parser Options
options = Options
  <$> strOption (long "dbpath" <> showDefault <> value "tesla.db" <> help "tesladb path")
  <*> strOption (long "vname" <> showDefault <> value "my car" <> help "name of vehicle to watch")
  <*> switch (long "disable-mqtt" <> help "disable MQTT support")
  <*> switch (short 'v' <> long "verbose" <> help "enable debug logging")
  <*> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> strOption (long "mqtt-topic" <> showDefault <> value "tmp/tesla" <> help "MQTT topic")
  <*> strOption (long "listen-topic" <> showDefault <> value "tmp/tesla/in/#" <> help "MQTT listen topics for syncing")
  <*> switch (long "enable-commands" <> help "enable remote commands")

dbSink :: VSink ()
dbSink = do
  Options{optDBPath} <- asks _sink_options
  ch <- asks _sink_chan
  liftIO $ withConnection optDBPath (storeThings ch)

  where
    storeThings ch db = do
      dbInit db

      forever $ atomically (readTChan ch) >>= insertVData db

mqttSink :: VSink ()
mqttSink = do
  opts@Options{optDBPath} <- asks _sink_options
  ch <- asks _sink_chan
  withRunInIO $ \unl -> withConnection optDBPath (\db -> withMQTT db opts unl (store opts ch unl))

  where
    withMQTT db opts unl = bracket (connect db opts unl) (disco opts unl)

    connect db opts@Options{..} unl = do
      unl $ logInfoL ["Connecting to ", tshow optMQTTURI]
      mc <- connectURI mqttConfig{_protocol=Protocol50,
                                  _msgCB=SimpleCallback (tdbAPI opts db unl)} optMQTTURI
      props <- svrProps mc
      unl $ logInfoL ["MQTT conn props from ", tshow optMQTTURI, ": ", tshow props]
      subr <- subscribe mc [(optInTopic, subOptions{_subQoS=QoS2})] mempty
      unl $ logInfoL ["MQTT sub response: ", tshow subr]
      pure mc

    disco Options{optMQTTURI} unl c = unl $ do
      logErrL ["disconnecting from ", tshow optMQTTURI]
      catch (liftIO $ normalDisconnect c) (\(e :: SomeException) ->
                                              logInfoL ["error disconnecting ", tshow e])
      logInfoL ["disconnected from ", tshow optMQTTURI]

    store Options{..} ch unl mc = forever $ do
      vdata <- atomically $ do
        connd <- isConnectedSTM mc
        unless connd $ throwM DisconnectedException
        readTChan ch
      void . unl . logDbg $ "Delivering vdata via MQTT"
      publishq mc optMQTTTopic vdata True QoS2 [PropMessageExpiryInterval 900,
                                                PropContentType "application/json"]
      unless (isUserPresent vdata) $ idiotCheck (openDoors vdata)
      unl . logDbg $ "Delivered vdata via MQTT"

        -- idiotCheck == verify state when user not present
        where idiotCheck [] = pure ()
              idiotCheck ds = publishq mc (optMQTTTopic <> "/alert/open")
                                       ("nobody's there, but the following doors are open: "
                                        <> (BC.pack . show) ds) False QoS2 []


    tdbAPI Options{..} db unl mc t m props = maybe (pure ()) toCall (cmd t)

      where
        toCall p = do
          tr <- timeout (seconds 10) $ call p ret m
          case tr of
            Nothing -> do
              unl $ logInfoL ["Timed out calling ", tshow p]
              respond ret "timed out" []
            Just _  -> pure ()

        cmd = T.stripPrefix (T.dropWhileEnd (== '#') optInTopic)

        ret = blToText . foldr f "" $ props
          where f (PropResponseTopic r) _ = r
                f _                     o = o

        rprops = filter f props
          where
            f PropCorrelationData{} = True
            f PropUserProperty{}    = True
            f _                     = False

        respond :: MonadIO m => Text -> BL.ByteString -> [Property] -> m ()
        respond "" _  _  = pure ()
        respond rt rm rp = liftIO $ publishq mc rt rm False QoS2 (rp <> rprops)

        callCMD rt a = unl $ runNamedCar optVName (loadAuthInfo optDBPath) $ do
          logInfoL ["Command requested: ", cmdname]
          r <- if optCMDsEnabled then a else pure (Left "command execution is disabled")
          logInfoL ["Finished command: ", cmdname, " with result: ", tshow r]
          respond rt (res r) []
            where cmdname = fromJust . cmd $ t
                  res = either textToBL (const "")

        callDBL res x a = case readTwo x of
                            Just ts -> callCMD res $ a ts
                            Nothing -> respond res "Could not parse arguments (expected two double values)" []


        doSeat res seat level = callCMD res $ CMD.heatSeat seat d
          where d = fromMaybe 0 (readMaybe . BC.unpack $ level)

        readTwo x = case traverse readMaybe (words . BC.unpack $ x) of
                      (Just [a,b]) -> Just (a,b)
                      _            -> Nothing

        call "cmd/sw/schedule" res x = callCMD res $ CMD.scheduleUpdate d
          where d = fromMaybe 0 (readMaybe . BC.unpack $ x)

        call "cmd/sw/cancel" res _ = callCMD res CMD.cancelUpdate

        call "cmd/charging/start" res _ = callCMD res CMD.startCharging
        call "cmd/charging/stop" res _ = callCMD res CMD.stopCharging
        call "cmd/charging/limit" res x = callCMD res $ CMD.setLimit d
          where d = fromMaybe 80 (readMaybe . BC.unpack $ x)

        call "cmd/hvac/on" res _ = callCMD res CMD.hvacOn
        call "cmd/hvac/off" res _ = callCMD res CMD.hvacOff
        call "cmd/hvac/wheel" res x = callCMD res $ CMD.wheelHeater (x == "on")

        call "cmd/hvac/seat/driver" res x     = doSeat res CMD.DriverSeat x
        call "cmd/hvac/seat/passenger" res x  = doSeat res CMD.PassengerSeat x
        call "cmd/hvac/seat/rearleft" res x   = doSeat res CMD.RearLeftSeat x
        call "cmd/hvac/seat/rearcenter" res x = doSeat res CMD.RearCenterSeat x
        call "cmd/hvac/seat/rearright" res x  = doSeat res CMD.RearRightSeat x

        call "cmd/alerts/honk" res _ = callCMD res CMD.honkHorn
        call "cmd/alerts/flash" res _ = callCMD res CMD.flashLights

        call "cmd/hvac/temps" res x = callDBL res x CMD.setTemps

        call "cmd/share" res x = callCMD res $ CMD.share (blToText x)

        call "cmd/windows/vent" res _ = callCMD res CMD.ventWindows
        call "cmd/windows/close" res x = callDBL res x CMD.closeWindows

        call "cmd/homelink/trigger" res x = callDBL res x CMD.trigger

        -- All RPCs below require a response topic.

        call p "" _ = unl $ logInfoL ["request to ", tshow p, " with no response topic"]

        call "days" res _ = do
          unl $ logInfoL ["Days call responding to ", tshow res]
          days <- listDays db
          respond res (encode . Map.fromList $ days) [PropContentType "application/json"]

        call "day" res d = do
          unl $ logInfoL ["Day call for ", tshow d, " responding to ", tshow res]
          days <- listDay db (BC.unpack d)
          respond res (encode days) [PropContentType "application/json"]

        call "fetch" res tss = do
          unl $ logInfoL ["Fetch call for ", tshow tss, " responding to ", tshow res]
          let mts = decode ("\"" <> tss <> "\"")
          guard $ isJust mts
          vdata <- fetchDatum db (fromJust mts)
          respond res vdata [PropContentType "application/json"]

        call x res _ = do
          unl $ logInfoL ["Call to invalid path: ", tshow x]
          respond res "Invalid command" []

gather :: Options -> TChan VehicleData -> LoggingT IO ()
gather Options{..} ch = runNamedCar optVName (loadAuthInfo optDBPath) $ do
    vid <- currentVehicleID
    logInfoL ["Looping with vid: ", vid]

    timeLoop fetch (process vid)

  where
    naptime :: VehicleData -> Int
    naptime vdata
          | isUserPresent vdata =  60
          | isCharging vdata    = 300
          | otherwise           = 600

    fetch = isAwake >>= \awake -> if awake then (Just <$> vehicleData) else pure Nothing

    process _ Nothing = logInfo "No data, must be sleeping or something" *> pure 300
    process vid (Just vdata) = do
      logInfoL ["Fetched data for vid: ", vid]
      liftIO . atomically $ writeTChan ch vdata
      let nt = naptime vdata
      logInfoL ["Sleeping for ", tshow nt,
                " user present: ", tshow $ isUserPresent vdata,
                ", charging: ", tshow $ isCharging vdata]
      pure nt

run :: Options -> IO ()
run opts@Options{optNoMQTT, optVerbose} =
  runSinks optVerbose opts gather ([dbSink, watchdogSink (3600 * 12)]
                                    <> [excLoop "mqtt" mqttSink | not optNoMQTT])

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Move stuff.")
