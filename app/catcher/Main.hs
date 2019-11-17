{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import qualified Control.Exception          as E
import           Control.Monad              (when, (<=<))
import           Data.Aeson                 (decode, encode)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.Foldable              (traverse_)
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromJust)
import           Data.Set                   (Set)
import qualified Data.Set                   as Set
import           Data.Text                  (Text, dropWhileEnd)
import qualified Data.Text.Encoding         as TE
import           Data.Time.Clock            (UTCTime)
import           Data.Time.Format           (defaultTimeLocale, formatTime)
import           Data.Time.LocalTime        (getCurrentTimeZone, utcToLocalTime)
import           Data.Word                  (Word32)
import           Database.SQLite.Simple     hiding (bind, close)
import           Network.MQTT.Client
import qualified Network.MQTT.RPC           as MQTTRPC
import           Network.MQTT.Types         (RetainHandling (..))
import           Network.URI
import           Options.Applicative        (Parser, auto, execParser, fullDesc,
                                             help, helper, info, long,
                                             maybeReader, option, progDesc,
                                             showDefault, strOption, switch,
                                             value, (<**>))
import           System.Log.Logger          (Priority (DEBUG), debugM, errorM,
                                             infoM, rootLoggerName, setLevel,
                                             updateGlobalLogger)

import           Tesla
import           TeslaDB

data Options = Options {
  optDBPath         :: String
  , optMQTTURI      :: URI
  , optMQTTTopic    :: Text
  , optBackfill     :: Bool
  , optSessionTime  :: Word32
  , optCleanSession :: Bool
  }

blToText :: BL.ByteString -> Text
blToText = TE.decodeUtf8 . BL.toStrict

options :: Parser Options
options = Options
  <$> strOption (long "dbpath" <> showDefault <> value "tesla.db" <> help "tesladb path")
  <*> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> strOption (long "mqtt-topic" <> showDefault <> value "tmp/tesla" <> help "MQTT topic")
  <*> switch (long "backfill" <> help "Perform a backfill via MQTT")
  <*> option auto (long "session-expiry" <> showDefault <> value 3600 <> help "Session expiration")
  <*> switch (long "clean-session" <> help "Clean the MQTT session")

type Callback = MQTTClient -> Topic -> BL.ByteString -> [Property] -> IO ()

withMQTT :: Options -> Callback -> (MQTTClient -> IO ()) -> IO ()
withMQTT Options{..} cb = E.bracket conn normalDisconnect
  where
    conn = do
      mc <- connectURI mqttConfig{_cleanSession=False,
                                  _protocol=Protocol50,
                                  _msgCB=SimpleCallback cb,
                                  _connProps=[PropReceiveMaximum 65535,
                                              PropSessionExpiryInterval optSessionTime,
                                              PropTopicAliasMaximum 10,
                                              PropRequestResponseInformation 1,
                                              PropRequestProblemInformation 1]}
            optMQTTURI
      props <- svrProps mc
      debugM rootLoggerName $ mconcat ["MQTT connected: ", show props]
      pure mc

tryInsert :: Connection -> VehicleData -> IO ()
tryInsert db vd = E.catch (insertVData db vd)
                  (\ex -> errorM rootLoggerName $ mconcat ["Error on ", show . maybeTeslaTS $ vd, ": ",
                                                           show (ex :: SQLError)])

backfill :: Connection -> MQTTClient -> Topic -> IO ()
backfill db mc dtopic = do
  infoM rootLoggerName $ "Beginning backfill"
  Just rdays <- decode <$> MQTTRPC.call mc (topic "days") "" :: IO (Maybe (Map String Int))
  ldays <- Map.fromList <$> listDays db
  let dayDiff = Map.keys $ Map.differenceWith (\a b -> if a == b then Nothing else Just a) rdays ldays

  traverse_ doDay dayDiff
  infoM rootLoggerName $ "Backfill complete"

    where
      topic x = dropWhileEnd (/= '/') dtopic <> "in/" <> x
      doDay d = do
        infoM rootLoggerName $ mconcat ["Backfilling ", d]
        Just rday <- decode <$> MQTTRPC.call mc (topic "day") (BC.pack d) :: IO (Maybe (Set UTCTime))
        lday <- Set.fromList <$> listDay db d

        traverse_ doOne (Set.difference rday lday)

      doOne ts = do
        let (Just k) = (inner . encode) ts
        debugM rootLoggerName $ mconcat ["Fetching remote data from ", show ts]
        vd <- MQTTRPC.call mc (topic "fetch") k
        tryInsert db vd

          where inner = BL.stripPrefix "\"" <=< BL.stripSuffix "\""

run :: Options -> IO ()
run opts@Options{..} = do
  updateGlobalLogger rootLoggerName (setLevel DEBUG)

  withConnection optDBPath storeThings

  where
    sink db _ _ m _ = do
      tz <- getCurrentTimeZone
      let lt = utcToLocalTime tz . teslaTS $ m
      debugM rootLoggerName $ mconcat ["Received data ", formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q %Z" lt]
      tryInsert db m

    storeThings db = do
      dbInit db

      withMQTT opts (sink db) $ \mc -> do
        subr <- subscribe mc [(optMQTTTopic, subOptions{_subQoS=QoS2, _retainHandling=SendOnSubscribeNew})] mempty
        debugM rootLoggerName $ mconcat ["Sub response: ", show subr]

        when optBackfill $ backfill db mc optMQTTTopic

        waitForClient mc

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "sink tesladb from mqtt")
