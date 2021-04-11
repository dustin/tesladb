{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Concurrent.STM  (TChan, atomically, dupTChan, newBroadcastTChanIO, readTChan, writeTChan)
import           Control.Lens
import           Control.Monad           (forever, unless, void)
import           Control.Monad.Catch     (SomeException (..), bracket, catch, throwM)
import           Control.Monad.IO.Class  (MonadIO (..))
import           Control.Monad.IO.Unlift (withRunInIO)
import           Control.Monad.Logger    (LogLevel (..), LoggingT, MonadLogger, filterLogger, runStderrLoggingT)
import           Control.Monad.Reader    (ReaderT (..), asks, runReaderT)
import           Data.Aeson              (Value (..), encode)
import           Data.Aeson.Lens
import           Data.Maybe              (fromJust)
import           Data.Text               (Text)
import           Network.MQTT.Client
import           Network.URI
import           Options.Applicative     (Parser, auto, execParser, fullDesc, help, helper, info, long, maybeReader,
                                          option, progDesc, short, showDefault, strOption, switch, value, (<**>))
import           UnliftIO.Async          (race_)
import           UnliftIO.Timeout        (timeout)

import           Tesla                   (EnergyID)
import           Tesla.AuthDB
import           Tesla.Energy
import           Tesla.Runner

data Options = Options {
  optDBPath      :: FilePath
  , optEID       :: EnergyID
  , optVerbose   :: Bool
  , optMQTTURI   :: URI
  , optMQTTTopic :: Text
  , optInTopic   :: Text
  }

options :: Parser Options
options = Options
  <$> strOption (long "dbpath" <> showDefault <> value "tesla.db" <> help "tesladb path")
  <*> option auto (long "eid" <> showDefault <> help "ID of energy site")
  <*> switch (short 'v' <> long "verbose" <> help "enable debug logging")
  <*> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> strOption (long "mqtt-topic" <> showDefault <> value "tmp/tesla" <> help "MQTT topic")
  <*> strOption (long "listen-topic" <> showDefault <> value "tmp/tesla/in/#" <> help "MQTT listen topics for syncing")

mqttSink :: (Sink Options Value) ()
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

lifeTime :: Num a => a
lifeTime = 900

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

run :: Options -> IO ()
run opts@Options{optVerbose} = withLog $ do
  tch <- liftIO newBroadcastTChanIO
  let sinks = [excLoop "mqtt" mqttSink, watchdogSink (3*lifeTime)]
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
