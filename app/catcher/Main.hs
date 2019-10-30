{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Data.Maybe             (fromJust)
import           Data.Text              (Text)
import           Database.SQLite.Simple hiding (bind, close)
import           Network.MQTT.Client
import           Network.MQTT.Types     (RetainHandling (..))
import           Network.URI
import           Options.Applicative    (Parser, execParser, fullDesc, help,
                                         help, helper, info, long, maybeReader,
                                         option, progDesc, showDefault,
                                         strOption, value, (<**>))
import           System.Log.Logger      (Priority (DEBUG), debugM,
                                         rootLoggerName, setLevel,
                                         updateGlobalLogger)

import           Tesla
import           TeslaDB

data Options = Options {
  optDBPath      :: String
  , optMQTTURI   :: URI
  , optMQTTTopic :: Text
  }

options :: Parser Options
options = Options
  <$> strOption (long "dbpath" <> showDefault <> value "tesla.db" <> help "tesladb path")
  <*> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> strOption (long "mqtt-topic" <> showDefault <> value "tmp/tesla" <> help "MQTT topic")

run :: Options -> IO ()
run Options{..} = do
  updateGlobalLogger rootLoggerName (setLevel DEBUG)

  withConnection optDBPath storeThings

  where
    sink db _ _ m _ = do
      debugM rootLoggerName $ mconcat ["Received data ", (show . teslaTS) m]
      insertVData db m

    storeThings db = do
      dbInit db

      mc <- connectURI mqttConfig{_cleanSession=False,
                                  _protocol=Protocol50,
                                  _msgCB=SimpleCallback (sink db),
                                  _connProps=[PropReceiveMaximum 65535,
                                              PropSessionExpiryInterval 3600,
                                              PropTopicAliasMaximum 10,
                                              PropRequestResponseInformation 1,
                                              PropRequestProblemInformation 1]}
            optMQTTURI
      props <- svrProps mc
      debugM rootLoggerName $ mconcat ["MQTT connected: ", show props]
      subr <- subscribe mc [(optMQTTTopic, subOptions{_subQoS=QoS2, _retainHandling=SendOnSubscribeNew})] mempty
      debugM rootLoggerName $ mconcat ["Sub response: ", show subr]

      waitForClient mc

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "sink tesladb from mqtt")
