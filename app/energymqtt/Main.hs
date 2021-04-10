{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.Async   (AsyncCancelled (..))
import           Control.Concurrent.STM     (TChan, atomically, dupTChan, newBroadcastTChanIO, orElse, readTChan,
                                             readTVar, registerDelay, retry, writeTChan)
import           Control.Lens
import           Control.Monad              (forever, unless, void)
import           Control.Monad.Catch        (Exception, Handler (..), MonadCatch, SomeException (..), bracket, catch,
                                             catches, throwM)
import           Control.Monad.IO.Class     (MonadIO (..))
import           Control.Monad.IO.Unlift    (MonadUnliftIO, withRunInIO)
import           Control.Monad.Logger       (LogLevel (..), LoggingT, MonadLogger, filterLogger, logDebugN, logErrorN,
                                             logInfoN, runStderrLoggingT)
import           Control.Monad.Reader       (ReaderT (..), asks, runReaderT)
import           Data.Aeson                 (Value (..), encode)
import           Data.Aeson.Lens
import qualified Data.ByteString.Lazy       as BL
import           Data.Maybe                 (fromJust)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as TE
import           Network.MQTT.Client
import           Network.URI
import           Options.Applicative        (Parser, auto, execParser, fullDesc, help, helper, info, long, maybeReader,
                                             option, progDesc, short, showDefault, strOption, switch, value, (<**>))
import           UnliftIO.Async             (async, race_, waitAnyCancel)
import           UnliftIO.Timeout           (timeout)

import           Tesla                      (EnergyID)
import           Tesla.AuthDB
import           Tesla.Energy

data Options = Options {
  optDBPath      :: FilePath
  , optEID       :: EnergyID
  , optVerbose   :: Bool
  , optMQTTURI   :: URI
  , optMQTTTopic :: Text
  , optInTopic   :: Text
  }

data SinkEnv = SinkEnv {
  _sink_options :: Options,
  _sink_chan    :: TChan Value
  }

type Sink = ReaderT SinkEnv (LoggingT IO)

options :: Parser Options
options = Options
  <$> strOption (long "dbpath" <> showDefault <> value "tesla.db" <> help "tesladb path")
  <*> option auto (long "eid" <> showDefault <> help "ID of energy site")
  <*> switch (short 'v' <> long "verbose" <> help "enable debug logging")
  <*> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> strOption (long "mqtt-topic" <> showDefault <> value "tmp/tesla" <> help "MQTT topic")
  <*> strOption (long "listen-topic" <> showDefault <> value "tmp/tesla/in/#" <> help "MQTT listen topics for syncing")

newtype DeathException = Die String deriving(Eq, Show)

instance Exception DeathException

logErr :: MonadLogger m => Text -> m ()
logErr = logErrorN

logInfo :: MonadLogger m => Text -> m ()
logInfo = logInfoN

logDbg :: MonadLogger m => Text -> m ()
logDbg = logDebugN

tshow :: Show a => a -> Text
tshow = T.pack . show

excLoop :: Text -> Sink () -> Sink ()
excLoop n s = forever $ catches s [Handler cancelHandler, Handler otherHandler]

  where
    cancelHandler :: (MonadCatch m, MonadLogger m, MonadIO m) => AsyncCancelled -> m ()
    cancelHandler e = logErr "AsyncCanceled from mqtt handler" >> throwM e

    otherHandler :: (MonadCatch m, MonadLogger m, MonadIO m) => SomeException -> m ()
    otherHandler e = do
      logErr $ mconcat ["Caught exception in handler: ", n, " - ", tshow e, " retrying shortly"]
      sleep 5

mqttSink :: Sink ()
mqttSink = do
  opts <- asks _sink_options
  ch <- asks _sink_chan
  withRunInIO $ \unl -> withMQTT opts unl (store opts ch unl)

  where
    withMQTT opts unl = bracket (connect opts unl) (disco opts unl)

    connect Options{..} unl = do
      void . unl . logInfo $ mconcat ["Connecting to ", tshow optMQTTURI]
      mc <- connectURI mqttConfig{_protocol=Protocol50} optMQTTURI
      props <- svrProps mc
      void . unl . logInfo $ mconcat ["MQTT conn props from ", tshow optMQTTURI, ": ", tshow props]
      subr <- subscribe mc [(optInTopic, subOptions{_subQoS=QoS2})] mempty
      void . unl . logInfo $ mconcat ["MQTT sub response: ", tshow subr]
      pure mc

    disco Options{optMQTTURI} unl c = unl $ do
      logErr $ "disconnecting from " <> tshow optMQTTURI
      catch (liftIO $ normalDisconnect c) (\(e :: SomeException) ->
                                              logInfo $ "error disconnecting " <> tshow e)
      logInfo $ "disconnected from " <> tshow optMQTTURI

    store Options{..} ch unl mc = forever $ do
      edata <- atomically $ do
        connd <- isConnectedSTM mc
        unless connd $ throwM DisconnectedException
        readTChan ch
      void . unl . logDbg $ "Delivering data via MQTT"
      let d = encode ((edata :: Value) ^?! key "response")
      publishq mc optMQTTTopic d True QoS2 [PropMessageExpiryInterval (lifeTime*2),
                                            PropContentType "application/json"]
      unl . logDbg $ "Delivered vdata via MQTT"

watchdogSink :: Sink ()
watchdogSink = do
  ch <- asks _sink_chan
  tov <- liftIO $ registerDelay (seconds (3 * lifeTime))
  again <- liftIO $ atomically $ (True <$ readTChan ch) `orElse` checkTimeout tov
  logDbg $ "Watchdog returned " <> tshow again
  unless again $ liftIO $ die "Watchdog timeout"
  watchdogSink

    where
      checkTimeout v = do
        v' <- readTVar v
        unless v' retry
        pure False

data DisconnectedException = DisconnectedException deriving Show

instance Exception DisconnectedException

blToText :: BL.ByteString -> Text
blToText = TE.decodeUtf8 . BL.toStrict

textToBL :: Text -> BL.ByteString
textToBL = BL.fromStrict . TE.encodeUtf8

die :: String -> IO ()
die = throwM . Die

sleep :: MonadIO m => Int -> m ()
sleep = liftIO . threadDelay . seconds

seconds :: Int -> Int
seconds = (* 1000000)

lifeTime :: Num a => a
lifeTime = 1800

gather :: Options -> TChan Value -> LoggingT IO ()
gather Options{..} ch = runEnergy (loadAuthInfo optDBPath) optEID $ do
    logInfo $ mconcat ["Looping with eid: ", tshow optEID]

    forever $ do
      logDbg "Fetching"
      edata <- timeout (seconds 10) siteData
      sleep =<< process edata

  where
    process :: (MonadLogger m, MonadIO m) => Maybe Value -> m Int
    process Nothing = logErr "Timed out, retrying in 60s" >> pure 60
    process (Just edata) = do
      logInfo $ mconcat ["Fetched data for eid: ", tshow optEID]
      liftIO . atomically $ writeTChan ch edata
      pure lifeTime -- sleep time

raceABunch_ :: MonadUnliftIO m => [m a] -> m ()
raceABunch_ is = traverse async is >>= void.waitAnyCancel

run :: Options -> IO ()
run opts@Options{optVerbose} = withLog $ do
  tch <- liftIO newBroadcastTChanIO
  let sinks = [excLoop "mqtt" mqttSink, watchdogSink]
  race_ (gather opts tch) (raceABunch_ ((\f -> runSink f =<< d tch) <$> sinks))

  where

    d ch = liftIO . atomically $ dupTChan ch
    runSink f ch = runReaderT f (SinkEnv opts ch)
    logfilt = filterLogger (\_ -> flip (if optVerbose then (>=) else (>)) LevelDebug)
    withLog :: MonadIO m => LoggingT m a -> m a
    withLog = runStderrLoggingT . logfilt

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Move stuff.")
