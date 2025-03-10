module Main where

import           Cleff
import           Cleff.Mask                 (Mask (..), bracket, runMask)
import           Control.Lens
import           Control.Monad              (forever, unless)
import           Control.Monad.Catch        (MonadCatch (..), SomeException (..), catch, throwM, try)
import           Data.Aeson                 (Value, decode, encode)
import           Data.Aeson.Lens
import           Data.Bifunctor             (first)
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.Foldable              (asum)
import           Data.Functor               (($>))
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromJust, fromMaybe, mapMaybe)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
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
import           Tesla.Car                  (VehicleData, currentVehicleID, isCharging, isUserPresent, locationData,
                                             openDoors, runNamedCar, vdata, vehicleData)
import qualified Tesla.Car.Commands         as CMD
import           Tesla.DB
import           Tesla.RunDB
import           Tesla.Runner

import           Tesla.CarFX
import           Tesla.Logging
import           Tesla.MQTTFX
import           Tesla.Sink
import           Tesla.Types

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

dbSink :: [IOE, DB, Sink] :>> es => Eff es ()
dbSink = forever (runAtomicSink readTChan) >>= \case
            VData v -> insertVData v
            _       -> pure ()

mqttSink :: forall es. [IOE, Mask, LogFX, CarFX, DB, Sink] :>> es => Eff es ()
mqttSink = do
  opts <- sinkOption opts
  rug <- sinkOption loopRug
  withMQTT opts rug (store opts)

  where
    withMQTT opts rug a = bracket (connect opts rug) (disco opts) (flip runMQTT a)

    connect :: Options -> TVar Bool -> Eff es MQTTClient
    connect opts@Options{..} rug = do
      logInfoL ["Connecting to ", tshow optMQTTURI]
      withRunInIO $ \unl -> do
        mc <- liftIO $ connectURI mqttConfig{_protocol=Protocol50,
                                             _msgCB=SimpleCallback (\mc t b props -> unl $ runMQTT mc $ tdbAPI opts rug t b props)} optMQTTURI
        props <- svrProps mc
        unl $ logInfoL ["MQTT conn props from ", tshow optMQTTURI, ": ", tshow props]
        subr <- subscribe mc [(optInTopic, subOptions{_subQoS=QoS2})] mempty
        unl $ logInfoL ["MQTT sub response: ", tshow subr]
        pure mc

    disco Options{optMQTTURI} c = do
      logErrorL ["disconnecting from ", tshow optMQTTURI]
      catch (liftIO $ normalDisconnect c) (\(e :: SomeException) ->
                                              logInfoL ["error disconnecting ", tshow e])
      logInfoL ["disconnected from ", tshow optMQTTURI]

    store Options{..} = forever $ do
      checkConn <- atomicMQTT isConnectedSTM
      readObs <- atomicSink readTChan
      obs <- atomically $ do
        connd <- checkConn
        unless connd $ throwM DisconnectedException
        readObs
      logDbg "Delivering vdata via MQTT"
      case obs of
        VData v -> do
          publishRetained optMQTTTopic 86400 v
          unless (isUserPresent v) $ idiotCheck (openDoors v)

          -- idiotCheck == verify state when user not present
            where idiotCheck [] = pure ()
                  idiotCheck ds = publishEphemeral (optMQTTTopic <> "/alert/open") (encode (show <$> ds))
        PData p -> mapConcurrently_ (\(k,v) ->  publishRetained k 1800 v) (expand p)
          where
            expand j = (optMQTTProds, encode j) : mapMaybe aj (j ^.. key "response" . _Array . folded . to enc)
            aj (Just a, b) = Just (optMQTTProds <> a, b)
            aj _           = Nothing
            enc v = (akey v, encode v)
            akey v = mkTopic =<< asum [v ^? key "id_s" . _String, v ^? key "id" . _String]

      logDbg "Delivered vdata via MQTT"

    tdbAPI Options{..} rug t m props = maybe (pure ()) toCall (cmd t)

      where
        toCall :: Text -> Eff (MQTTFX : es) ()
        toCall p = timeout (seconds 10) (call p ret m) >>= \case
            Nothing -> do
              logInfoL ["Timed out calling ", tshow p]
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

        respond Nothing _  _    = pure ()
        respond (Just rt) rm rp = publishMQTT rt 0 rm (rp <> rprops)

        callCMD rt a = do
          logInfoL ["Command requested: ", cmdname]
          r <- if optCMDsEnabled then go else pure (Left "command execution is disabled")
          logInfoL ["Finished command: ", cmdname, " with result: ", tshow r]
          respond rt (res r) []
            where cmdname = fromJust . cmd $ t
                  res = either textToBL (const "")
                  go = catch (runCar a) (\(e :: SomeException) ->
                    let msg = "exception occurred in action " <> tshow e in logInfo msg $> Left msg)


        callDBL res x a = case readTwo x of
                            Just ts -> callCMD res $ a ts
                            Nothing -> respond res "Could not parse arguments (expected two double values)" []

        readTwo x = case traverse readMaybe (words . BC.unpack $ x) of
                      (Just [a,b]) -> Just (a,b)
                      _            -> Nothing

        call "cmd/sw/schedule" res x = callCMD res $ CMD.scheduleUpdate d
          where d = fromMaybe 0 (readMaybe . BC.unpack $ x)

        call "cmd/sw/cancel" res _ = callCMD res CMD.cancelUpdate

        call "cmd/charging/start" res _ = callCMD res CMD.startCharging
        call "cmd/charging/stop" res _ = callCMD res CMD.stopCharging
        call "cmd/charging/limit" res x = callCMD res $ CMD.setLimit d
          where d = fromMaybe (fromJust $ read "80") (readMaybe . BC.unpack $ x)

        call "cmd/hvac/on" res _ = callCMD res CMD.hvacOn
        call "cmd/hvac/off" res _ = callCMD res CMD.hvacOff
        call "cmd/hvac/wheel" res x = callCMD res $ CMD.wheelHeater (x == "on")

        call "cmd/alerts/honk" res _ = callCMD res CMD.honkHorn
        call "cmd/alerts/flash" res _ = callCMD res CMD.flashLights

        call "cmd/hvac/temps" res x = callDBL res x CMD.setTemps

        call "cmd/share" res x = callCMD res $ CMD.share (blToText x)

        call "cmd/windows/vent" res _ = callCMD res CMD.ventWindows
        call "cmd/windows/close" res x = callDBL res x CMD.closeWindows

        call "cmd/homelink/trigger" res x = callDBL res x CMD.homelink

        call "cmd/wake" res _ = callCMD res (CMD.wakeUp @Value $> Right ())

        call "cmd/poll" _ _ = atomically $ writeTVar rug True

        call "cmd/sleep" res _ = do
          p <- sinkOption prereq
          atomically $ writeTVar p CheckAsleep
          logInfo "Switching to checkAsleep"
          respond res "OK" []

        -- All RPCs below require a response topic.

        call p Nothing _ = logInfoL ["request to ", tshow p, " with no response topic"]

        call "days" res _ = do
          logInfoL ["Days call responding to ", tshow res]
          days <- listDays
          respond res (encode . Map.fromList $ days) [PropContentType "application/json"]

        call "day" res d = do
          logInfoL ["Day call for ", tshow d, " responding to ", tshow res]
          days <- listDay (BC.unpack d)
          respond res (encode days) [PropContentType "application/json"]

        call "fetch" res tss = do
          logInfoL ["Fetch call for ", tshow tss, " responding to ", tshow res]
          case decode ("\"" <> tss <> "\"") of
            Nothing -> pure ()
            Just ts -> do
              v <- fetchDatum ts
              respond res v [PropContentType "application/json"]

        call x res _ = do
          logInfoL ["Call to invalid path: ", tshow x]
          respond res "Invalid command" []

checkAwake' :: VehicleState -> Eff es (Either Text ())
checkAwake' VOnline = pure $ Right ()
checkAwake' st      = pure $ Left ("not awake, current status: " <> tshow st)

checkAsleep' :: IOE :> es => TVar PrereqAction -> VehicleState -> Eff es (Either Text ())
checkAsleep' _ VOnline = pure $ Left "not asleep"
checkAsleep' p _       = atomically $ writeTVar p CheckAwake $> Left "transitioned to checkAwake"

gather :: [IOE, CarFX, DB, LogFX] :>> es => State -> TChan Observation -> Eff es ()
gather (State _opts pv loopRug) ch = do
    vid <- currentVehicle
    logInfoL ["Looping with vid: ", vid]
    timeLoop loopRug fetch process

  where
    naptime :: VehicleData -> Int
    naptime v
          | isUserPresent v =  60
          | isCharging v    = 300
          | otherwise       = 900

    fetch = do
      ai <- loadAuthInfo
      prods <- productsRaw ai
      liftIO . atomically $ writeTChan ch (PData prods)
      vid <- currentVehicle
      let state = decodeProducts prods ^?! folded . _ProductVehicle . filtered (\(_,a,_) -> a == vid) . _3
      pa <- (liftIO . readTVarIO) pv
      st <- case pa of
        CheckAwake  -> checkAwake' state
        CheckAsleep -> checkAsleep' pv state
      either (pure . Left) (const (tryt mergedData)) st

    tryt :: MonadCatch m => m a -> m (Either Text a)
    tryt f = try @_ @SomeException f <&> first (T.pack . show)

    mergedData = runCar do
      v <- vehicleData
      -- If location data returns valid drive state, patch it into the larger one.
      loc <- try @_ @SomeException locationData
      case loc ^? _Right . vdata . key "drive_state" of
        Nothing -> pure v
        Just d  -> pure (v & vdata . key "drive_state" .~ d)

    process (Left s) = logInfoL ["No data: ", s] $> 300
    process (Right v) = do
      vid <- currentVehicle
      logInfoL ["Fetched data for vid: ", vid]
      liftIO . atomically $ writeTChan ch (VData v)
      let nt = naptime v
      logInfoL ["Sleeping for ", tshow nt,
                 ", user present: ", tshow $ isUserPresent v,
                 ", charging: ", tshow $ isCharging v]
      pure nt

run :: Options -> IO ()
run opts@Options{optNoMQTT, optVerbose, optVName, optDBPath} = do
  p <- newTVarIO CheckAwake
  rug <- newTVarIO False
  runIOE . runMask . withDB optDBPath $ do
    initDB
    vid <- withRunInIO $ \unl -> runNamedCar optVName (unl loadAuthInfo) currentVehicleID
    runLogFX optVerbose . runCarFX vid $ do
      let st = State opts p rug
      runSinks st gather ([dbSink, watchdogSink (3600 * 12)]
                                      <> [excLoop "mqtt" mqttSink | not optNoMQTT])

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Move stuff.")
