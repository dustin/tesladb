{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Concurrent.STM  (TChan, atomically, readTChan, writeTChan)
import           Control.Lens
import           Control.Monad           (forever, unless, void)
import           Control.Monad.Catch     (SomeException (..), bracket, catch, throwM)
import           Control.Monad.IO.Class  (MonadIO (..))
import           Control.Monad.IO.Unlift (withRunInIO)
import           Control.Monad.Logger    (LoggingT, MonadLogger)
import           Control.Monad.Reader    (asks)
import           Data.Aeson              (Value (..), encode)
import           Data.Aeson.Lens
import           Data.Maybe              (fromJust)
import           Data.Text               (Text)
import           Network.MQTT.Client
import           Network.URI
import           Options.Applicative     (Parser, auto, execParser, fullDesc, help, helper, info, long, maybeReader,
                                          option, progDesc, short, showDefault, strOption, switch, value, (<**>))

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
  }

options :: Parser Options
options = Options
  <$> strOption (long "dbpath" <> showDefault <> value "tesla.db" <> help "tesladb path")
  <*> option auto (long "eid" <> showDefault <> help "ID of energy site")
  <*> switch (short 'v' <> long "verbose" <> help "enable debug logging")
  <*> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> strOption (long "mqtt-topic" <> showDefault <> value "tmp/tesla" <> help "MQTT topic")

mqttSink :: (Sink Options Value) ()
mqttSink = do
  opts <- asks _sink_options
  ch <- asks _sink_chan
  withRunInIO $ \unl -> withMQTT opts unl (store opts ch unl)

  where
    withMQTT opts unl = bracket (connect opts unl) (disco opts unl)

    connect Options{..} unl = do
      void . unl $ logInfoL ["Connecting to ", tshow optMQTTURI]
      mc <- connectURI mqttConfig{_protocol=Protocol50} optMQTTURI
      props <- svrProps mc
      void . unl $ logInfoL ["MQTT conn props from ", tshow optMQTTURI, ": ", tshow props]
      pure mc

    disco Options{optMQTTURI} unl c = unl $ do
      logErrL ["disconnecting from ", tshow optMQTTURI]
      catch (liftIO $ normalDisconnect c) (\(e :: SomeException) ->
                                              logInfoL ["error disconnecting ", tshow e])
      logInfoL ["disconnected from ", tshow optMQTTURI]

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
gather Options{..} ch = runEnergy (loadAuthInfo optDBPath) optEID $ timeLoop siteData process
  where
    process :: (MonadLogger m, MonadIO m) => Value -> m Int
    process edata = liftIO . atomically $ writeTChan ch edata *> pure lifeTime

run :: Options -> IO ()
run opts@Options{optVerbose} =
  runSinks optVerbose opts gather [watchdogSink (3*lifeTime), excLoop "mqtt" mqttSink]

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "Move stuff.")
