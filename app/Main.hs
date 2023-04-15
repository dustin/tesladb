{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Lens
import           Control.Monad              (forever, guard, unless, void)
import           Control.Monad.Catch        (MonadCatch (..), SomeException (..), bracket, catch, throwM)
import           Control.Monad.IO.Class     (MonadIO (..))
import           Control.Monad.IO.Unlift    (MonadUnliftIO, withRunInIO)
import           Control.Monad.Logger       (MonadLogger (..))
import           Control.Monad.Reader       (asks)
import           Data.Aeson                 (Value, decode, encode)
import           Data.Aeson.Lens
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.Foldable              (asum)
import           Data.Functor               (($>))
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromJust, fromMaybe, isJust, mapMaybe)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Database.SQLite.Simple     hiding (bind, close)
import           Network.MQTT.Client
import           Network.MQTT.Topic
import           Network.URI
import           Options.Applicative        (Parser, execParser, fullDesc, help, helper, info, long, maybeReader,
                                             option, progDesc, short, showDefault, strOption, switch, value, (<**>))
import           Text.Read                  (readMaybe)
import           UnliftIO                   (TChan, TVar, atomically, mapConcurrently_, newTVarIO, readTChan,
                                             readTVarIO, writeTChan, writeTVar)
import           UnliftIO.Timeout           (timeout)

import           Tesla
import           Tesla.Auth
import           Tesla.AuthDB
import Tesla.Car
    ( currentVehicleID,
      isCharging,
      isUserPresent,
      openDoors,
      runNamedCar,
      vehicleData,
      Car,
      VehicleData )
import qualified Tesla.Car.Commands         as CMD
import           Tesla.Runner
import           Tesla.SqliteDB

data Options = Options {
  optDBPath        :: FilePath
  , optVName       :: Text
  , optNoMQTT      :: Bool
  , optVerbose     :: Bool
  , optMQTTURI     :: URI
  , optMQTTTopic   :: Topic
  , optInTopic     :: Filter
  , optCMDsEnabled :: Bool
  , optMQTTProds   :: Topic
  }

type PrereqAction m = VehicleState -> Car m (Either Text ())

data State m = State {
  opts     :: Options
  , prereq :: TVar (PrereqAction m)
  }

data Observation = VData VehicleData | PData Value

type VSink m = Sink (State m) Observation

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
  <*> strOption (long "product-topic" <> showDefault <> value "tmp/tesla/products" <> help "Raw product topic")

dbSink :: MonadIO m => (VSink m) ()
dbSink = do
  Options{optDBPath} <- asks (opts . _sink_options)
  ch <- asks _sink_chan
  liftIO $ withConnection optDBPath (storeThings ch)

  where
    storeThings ch db = do
      dbInit db

      forever $ atomically (readTChan ch) >>= \case
        VData v -> insertVData db v
        _       -> pure ()

mqttSink :: (MonadLogger m, MonadIO m) => (VSink m) ()
mqttSink = do
  opts@Options{optDBPath} <- asks (opts . _sink_options)
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
      obs <- atomically $ do
        connd <- isConnectedSTM mc
        unless connd $ throwM DisconnectedException
        readTChan ch
      void . unl . logDbg $ "Delivering vdata via MQTT"
      case obs of
        VData v -> do
          publishq mc optMQTTTopic v True QoS2 [PropMessageExpiryInterval 86400,
                                                PropContentType "application/json"]
          unless (isUserPresent v) $ idiotCheck (openDoors v)

          -- idiotCheck == verify state when user not present
            where idiotCheck [] = pure ()
                  idiotCheck ds = publishq mc (optMQTTTopic <> "/alert/open")
                                  ("nobody's there, but the following doors are open: "
                                   <> (BC.pack . show) ds) False QoS2 []
        PData p -> mapConcurrently_ (\(k,v) ->
                                       publishq mc k v True QoS2 [PropMessageExpiryInterval 1800,
                                                                  PropContentType "application/json"]) (expand p)
          where
            expand j = (optMQTTProds, encode j) : mapMaybe aj (j ^.. key "response" . _Array . folded . to enc)
            aj (Just a, b) = Just (optMQTTProds <> a, b)
            aj _           = Nothing
            enc v = (akey v, encode v)
            akey v = mkTopic =<< asum [v ^? key "id_s" . _String, v ^? key "id" . _String]

      unl . logDbg $ "Delivered vdata via MQTT"

    tdbAPI Options{..} db unl mc t m props = maybe (pure ()) toCall (cmd t)

      where
        toCall p = do
          tr <- timeout (seconds 10) $ call p ret m
          case tr of
            Nothing -> do
              unl $ logInfoL ["Timed out calling ", tshow p]
              respond ret "timed out" []
            Just _  -> pure ()

        cmd = T.stripPrefix (T.dropWhileEnd (== '#') (unFilter optInTopic)) . unTopic

        ret = foldr f Nothing props
          where f (PropResponseTopic r) _ = mkTopic . blToText $ r
                f _                     o = o

        rprops = filter f props
          where
            f PropCorrelationData{} = True
            f PropUserProperty{}    = True
            f _                     = False

        respond :: MonadIO m => Maybe Topic -> BL.ByteString -> [Property] -> m ()
        respond Nothing _  _    = pure ()
        respond (Just rt) rm rp = liftIO $ publishq mc rt rm False QoS2 (rp <> rprops)

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

        call "cmd/wake" res _ = callCMD res CMD.wakeUp

        call "cmd/sleep" res _ = do
          unl $ do
            p <- asks (prereq . _sink_options)
            atomically $ writeTVar p (checkAsleep p)
            logInfo "Switching to checkAsleep"
          respond res "OK" []

        -- All RPCs below require a response topic.

        call p Nothing _ = unl $ logInfoL ["request to ", tshow p, " with no response topic"]

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
          v <- fetchDatum db (fromJust mts)
          respond res v [PropContentType "application/json"]

        call x res _ = do
          unl $ logInfoL ["Call to invalid path: ", tshow x]
          respond res "Invalid command" []

checkAwake :: MonadIO m => PrereqAction m
checkAwake VOnline = pure $ Right ()
checkAwake st      = pure $ Left ("not awake, current status: " <> tshow st)

checkAsleep :: MonadIO m => TVar (PrereqAction m) -> PrereqAction m
checkAsleep _ VOnline = pure $ Left "not asleep"
checkAsleep p _       = atomically $ writeTVar p checkAwake $> Left "transitioned to checkAwake"

gather :: (MonadCatch m, MonadLogger m, MonadUnliftIO m) => State m -> TChan Observation -> m a
gather (State Options{..} pv) ch = runNamedCar optVName (loadAuthInfo optDBPath) $ do
    vid <- currentVehicleID
    logInfoL ["Looping with vid: ", vid]

    ai <- teslaAuth
    timeLoop (fetch ai vid) (process vid)

  where
    naptime :: VehicleData -> Int
    naptime v
          | isUserPresent v =  60
          | isCharging v    = 300
          | otherwise       = 900

    fetch ai vid = do
              prods <- productsRaw ai
              liftIO . atomically $ writeTChan ch (PData prods)
              let state = decodeProducts prods ^?! folded . _ProductVehicle . filtered (\(_,a,_) -> a == vid) . _3
              pa <- (liftIO . readTVarIO) pv
              either (pure . Left) (const vd) =<< pa state

    vd = catch (Right <$> vehicleData) (\(e :: SomeException) -> pure (Left (tshow e)))

    process _ (Left s) = logInfoL ["No data: ", s] $> 300
    process vid (Right v) = do
      logInfoL ["Fetched data for vid: ", vid]
      liftIO . atomically $ writeTChan ch (VData v)
      let nt = naptime v
      logInfoL ["Sleeping for ", tshow nt,
                " user present: ", tshow $ isUserPresent v,
                ", charging: ", tshow $ isCharging v]
      pure nt

run :: Options -> IO ()
run opts@Options{optNoMQTT, optVerbose} = do
  p <- newTVarIO checkAwake
  runSinks optVerbose (State opts p) gather ([dbSink, watchdogSink (3600 * 12)]
                                              <> [excLoop "mqtt" mqttSink | not optNoMQTT])

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Move stuff.")
