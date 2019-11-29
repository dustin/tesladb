{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.Async   (AsyncCancelled (..), async, race_,
                                             waitAnyCancel)
import           Control.Concurrent.STM     (TChan, atomically, dupTChan,
                                             newBroadcastTChanIO, orElse,
                                             readTChan, readTVar, registerDelay,
                                             retry, writeTChan)
import           Control.Exception          (Exception, Handler (..),
                                             SomeException (..), bracket,
                                             catches, throw, throwIO)
import           Control.Monad              (forever, guard, unless, void)
import           Control.Monad.IO.Class     (MonadIO (..))
import           Data.Aeson                 (decode, encode)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromJust, fromMaybe, isJust)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as TE
import           Database.SQLite.Simple     hiding (bind, close)
import           Network.MQTT.Client
import           Network.URI
import           Options.Applicative        (Parser, execParser, fullDesc, help,
                                             helper, info, long, maybeReader,
                                             option, progDesc, short,
                                             showDefault, strOption, switch,
                                             value, (<**>))
import           System.Log.Logger          (Priority (DEBUG, INFO), debugM,
                                             errorM, infoM, rootLoggerName,
                                             setLevel, updateGlobalLogger)
import           Text.Read                  (readMaybe)
import           UnliftIO.Timeout           (timeout)

import           Tesla
import           Tesla.AuthDB
import           Tesla.Car
import           Tesla.Command
import qualified Tesla.Command.Charging     as CMD
import qualified Tesla.Command.Climate      as CMD
import qualified Tesla.Command.Sharing      as CMD
import qualified Tesla.Command.Software     as CMD
import           Tesla.DB

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

newtype DeathException = Die String deriving(Eq, Show)

instance Exception DeathException

logErr :: MonadIO m => String -> m ()
logErr = liftIO . errorM rootLoggerName

logInfo :: MonadIO m => String -> m ()
logInfo = liftIO . infoM rootLoggerName

logDbg :: MonadIO m => String -> m ()
logDbg = liftIO . debugM rootLoggerName

excLoop :: String -> Sink -> Options -> TChan VehicleData  -> IO ()
excLoop n s opts ch = forever $ catches (s opts ch) [Handler cancelHandler,
                                                     Handler otherHandler]

  where
    cancelHandler :: AsyncCancelled -> IO ()
    cancelHandler e = logErr "AsyncCanceled from mqtt handler" >> throwIO e

    otherHandler :: SomeException -> IO ()
    otherHandler e = do
      logErr $ mconcat ["Caught exception in handler: ", n, " - ", show e, " retrying shortly"]
      threadDelay 5000000

watchdogSink :: Sink
watchdogSink o ch = do
  tov <- registerDelay (3*600000000)
  again <- atomically $ (True <$ readTChan ch) `orElse` checkTimeout tov
  logDbg $ "Watchdog returned " <> show again
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

textToBL :: Text -> BL.ByteString
textToBL = BL.fromStrict . TE.encodeUtf8

die :: String -> IO ()
die = throwIO . Die

mqttSink :: Sink
mqttSink opts@Options{..} ch = withConnection optDBPath (\db -> (withMQTT db) store)

  where
    withMQTT db = bracket (connect db) disco

    connect db = do
      logInfo $ mconcat ["Connecting to ", show optMQTTURI]
      mc <- connectURI mqttConfig{_protocol=Protocol50,
                                  _msgCB=SimpleCallback (tdbAPI db)} optMQTTURI
      props <- svrProps mc
      logInfo $ mconcat ["MQTT conn props from ", show optMQTTURI, ": ", show props]
      subr <- subscribe mc [(optInTopic, subOptions{_subQoS=QoS2})] mempty
      logInfo $ mconcat ["MQTT sub response: ", show subr]
      pure mc

    disco c = do
      logErr ("disconnecting from " <> show optMQTTURI)
      normalDisconnect c
      logInfo ("disconnected from " <> show optMQTTURI)

    store mc = forever $ do
      vdata <- atomically $ do
        connd <- isConnectedSTM mc
        unless connd $ throw DisconnectedException
        readTChan ch
      logDbg "Delivering vdata via MQTT"
      publishq mc optMQTTTopic vdata True QoS2 [PropMessageExpiryInterval 900,
                                                PropContentType "application/json"]
      unless (isUserPresent vdata) $ idiotCheck (openDoors vdata)
      logDbg "Delivered vdata via MQTT"

        -- idiotCheck == verify state when user not present
        where idiotCheck [] = pure ()
              idiotCheck ds = publishq mc (optMQTTTopic <> "/alert/open")
                                       ("nobody's there, but the following doors are open: "
                                        <> (BC.pack . show) ds) False QoS2 []


    tdbAPI db mc t m props = maybe (pure ()) (\x -> call x ret m) (cmd t)

      where
        cmd = T.stripPrefix (T.dropWhileEnd (== '#') optInTopic)

        ret = blToText . foldr f "" $ props
          where f (PropResponseTopic r) _ = r
                f _                     o = o

        rprops = filter f props
          where
            f (PropCorrelationData{}) = True
            f (PropUserProperty{})    = True
            f _                       = False

        callCMD :: Text -> Car CommandResponse -> IO ()
        callCMD rt a = runNamedCar optVName (toke opts) $ do
          logInfo $ mconcat ["Running command: ", cmdname]
          r <- a
          logInfo $ mconcat ["Finished command: ", cmdname, " with result: ", show r]
          liftIO $ publishq mc rt (res r) False QoS2 rprops
            where cmdname = T.unpack . fromJust . cmd $ t
                  res = either textToBL (const "")

        call "cmd/sw/schedule" res x = callCMD res $ CMD.schedule d
          where d = fromMaybe 0 (readMaybe . BC.unpack $ x)

        call "cmd/sw/cancel" res _ = callCMD res CMD.cancel

        call "cmd/charging/start" res _ = callCMD res CMD.startCharging
        call "cmd/charging/stop" res _ = callCMD res CMD.stopCharging
        call "cmd/charging/limit" res x = callCMD res $ CMD.setLimit d
          where d = fromMaybe 80 (readMaybe . BC.unpack $ x)

        call "cmd/hvac/on" res _ = callCMD res CMD.hvacOn
        call "cmd/hvac/off" res _ = callCMD res CMD.hvacOff
        call "cmd/hvac/wheel" res x = callCMD res $ CMD.wheelHeater (x == "on")
        -- TODO: seats and temps.  Have to think of how I want to express these.

        call "cmd/share" res x = callCMD res $ CMD.share (blToText x)

        -- everything below this is RPC and requires a response topic.

        call p "" _ = logInfo $ mconcat ["request to ", show p, " with no response topic"]

        call "days" res _ = do
          logInfo $ mconcat ["Days call responding to ", show res]
          days <- listDays db
          publishq mc res (encode . Map.fromList $ days) False QoS2 ([PropContentType "application/json"] <> rprops)

        call "day" res d = do
          logInfo $ mconcat ["Day call for ", show d, " responding to ", show res]
          days <- listDay db (BC.unpack d)
          publishq mc res (encode days) False QoS2 ([PropContentType "application/json"] <> rprops)

        call "fetch" res tss = do
          logInfo $ mconcat ["Fetch call for ", show tss, " responding to ", show res]
          let mts = decode ("\"" <> tss <> "\"")
          guard $ isJust mts
          vdata <- fetchDatum db (fromJust mts)
          publishq mc res vdata False QoS2 ([PropContentType "application/json"] <> rprops)

        call x _ _ = logInfo $ mconcat ["Call to invalid path: ", show x]

sleep :: MonadIO m => Int -> m ()
sleep = liftIO . threadDelay

toke :: Options -> IO AuthInfo
toke Options{..} = loadAuth optDBPath >>= \AuthResponse{..} -> pure $ fromToken _access_token

gather :: Options -> TChan VehicleData -> IO ()
gather opts@Options{..} ch = do
  runNamedCar optVName (toke opts) $ do
    vid <- vehicleID
    logInfo $ mconcat ["Looping with vid: ", show vid]

    forever $ do
      logDbg "Fetching"
      vdata <- timeout 10000000 vehicleData
      nt <- liftIO $ process (T.pack vid) vdata
      sleep nt

  where
    naptime :: VehicleData -> Int
    naptime vdata
          | isUserPresent vdata = 60000000
          | isCharging vdata    = 300000000
          | otherwise           = 600000000

    process :: Text -> Maybe VehicleData -> IO Int
    process _ Nothing = logErr "Timed out, retrying in 60s" >> pure 60000000
    process vid (Just vdata) = do
      logInfo $ mconcat ["Fetched data for vid: ", show vid]
      atomically $ writeTChan ch vdata
      let nt = naptime vdata
      logInfo $ mconcat ["Sleeping for ", show nt,
                                      " user present: ", show $ isUserPresent vdata,
                                      ", charging: ", show $ isCharging vdata]
      pure $ naptime vdata

raceABunch_ :: [IO a] -> IO ()
raceABunch_ is = traverse async is >>= void.waitAnyCancel

run :: Options -> IO ()
run opts@Options{optNoMQTT, optVerbose} = do
  updateGlobalLogger rootLoggerName (setLevel $ if optVerbose then DEBUG else INFO)

  tch <- newBroadcastTChanIO
  let sinks = [dbSink, watchdogSink] <> if optNoMQTT then [] else [excLoop "mqtt" mqttSink]
  race_ (gather opts tch) (raceABunch_ ((\f -> f opts =<< d tch) <$> sinks))

  where d ch = atomically $ dupTChan ch

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Move stuff.")
