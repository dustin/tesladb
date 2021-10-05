{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Monad              (unless, (<=<))
import qualified Control.Monad.Catch        as E
import           Control.Monad.IO.Class     (MonadIO (..))
import           Control.Monad.IO.Unlift    (MonadUnliftIO, withRunInIO)
import           Control.Monad.Logger       (LogLevel (..), LoggingT, MonadLogger, filterLogger, logWithoutLoc,
                                             runStderrLoggingT)
import           Control.Monad.Reader       (MonadReader, ReaderT, asks, runReaderT)
import           Data.Aeson                 (decode, encode)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.Foldable              (traverse_)
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromJust)
import           Data.Set                   (Set)
import qualified Data.Set                   as Set
import           Data.Text                  (Text, dropWhileEnd, pack)
import qualified Data.Text.Encoding         as TE
import           Data.Time.Clock            (UTCTime)
import           Data.Time.Format           (defaultTimeLocale, formatTime)
import           Data.Time.LocalTime        (getCurrentTimeZone, utcToLocalTime)
import           Data.Word                  (Word32)
import qualified Database.SQLite.Simple     as SQLite
import           Network.MQTT.Client
import qualified Network.MQTT.RPC           as MQTTRPC
import           Network.MQTT.Topic
import           Network.MQTT.Types         (RetainHandling (..))
import           Network.URI
import           Options.Applicative        (Parser, auto, execParser, fullDesc, help, helper, info, long, maybeReader,
                                             option, progDesc, short, showDefault, strOption, switch, value, (<**>))
import           UnliftIO.Async             (concurrently, mapConcurrently_)

import           Tesla.Car
import qualified Tesla.DB                   as DB

data Options = Options {
  optDBPath         :: String
  , optMQTTURI      :: URI
  , optMQTTTopic    :: Filter
  , optNoBackfill   :: Bool
  , optSessionTime  :: Word32
  , optCleanSession :: Bool
  , optVerbose      :: Bool
  }

class MonadIO m => Persistence m where
  listDays :: m [(String,Int)]
  listDay  :: m [UTCTime]
  insertVData :: VehicleData -> m ()

data SQLiteEnv = SQLiteEnv {
  sqliteConn :: SQLite.Connection
  }

type Sink = ReaderT SQLiteEnv (LoggingT IO)

blToText :: BL.ByteString -> Text
blToText = TE.decodeUtf8 . BL.toStrict

options :: Parser Options
options = Options
  <$> strOption (long "dbpath" <> showDefault <> value "tesla.db" <> help "tesladb path")
  <*> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> strOption (long "mqtt-topic" <> showDefault <> value "tmp/tesla" <> help "MQTT topic")
  <*> switch (long "disable-backfill" <> help "Disable backfill via MQTT")
  <*> option auto (long "session-expiry" <> showDefault <> value 3600 <> help "Session expiration")
  <*> switch (long "clean-session" <> help "Clean the MQTT session")
  <*> switch (short 'v' <> long "verbose" <> help "enable debug logging")

logAt :: MonadLogger m => LogLevel -> Text -> m ()
logAt = logWithoutLoc ""

logErr :: MonadLogger m => Text -> m ()
logErr = logAt LevelError

logInfo :: MonadLogger m => Text -> m ()
logInfo = logAt LevelInfo

logDbg :: MonadLogger m => Text -> m ()
logDbg = logAt LevelDebug

lstr :: Show a => a -> Text
lstr = pack . show

type Callback = MQTTClient -> Topic -> BL.ByteString -> [Property] -> IO ()

withMQTT :: (MonadIO m, E.MonadMask m, MonadLogger m) => Options -> Callback -> (MQTTClient -> m ()) -> m ()
withMQTT Options{..} cb = E.bracket conn (liftIO . normalDisconnect)
  where
    conn = do
      mc <- liftIO $ connectURI mqttConfig{_cleanSession=optSessionTime == 0,
                                           _protocol=Protocol50,
                                           _msgCB=SimpleCallback cb,
                                           _connProps=[PropReceiveMaximum 65535,
                                                       PropSessionExpiryInterval optSessionTime,
                                                       PropTopicAliasMaximum 10,
                                                       PropRequestResponseInformation 1,
                                                       PropRequestProblemInformation 1]}
            optMQTTURI
      ack <- liftIO $ connACK mc
      logDbg $ mconcat ["MQTT connected: ", lstr ack]
      pure mc

logData :: (MonadIO m, MonadLogger m) => VehicleData -> m ()
logData vd = unless (up || null od) $ logInfo $ mconcat [
  "User is not present, but the following doors are open at ", lstr ts, ": ", lstr od]
  where
    up = isUserPresent vd
    od = openDoors vd
    ts = teslaTS vd

tryInsert :: (MonadReader SQLiteEnv m, MonadLogger m, E.MonadCatch m, MonadIO m)
          => VehicleData -> m ()
tryInsert vd = asks sqliteConn >>= \db -> E.catch (liftIO $ DB.insertVData db vd)
                                          (\ex -> logErr $ mconcat ["Error on ", lstr . maybeTeslaTS $ vd, ": ",
                                                                    lstr (ex :: SQLite.SQLError)])

backfill :: (MonadReader SQLiteEnv m, MonadLogger m, E.MonadCatch m, MonadFail m, MonadUnliftIO m)
         => MQTTClient -> Filter -> m ()
backfill mc dfilter = asks sqliteConn >>= \db -> do
  logInfo "Beginning backfill"
  (Just rdays, ldays) <- concurrently remoteDays (Map.fromList <$> liftIO (DB.listDays db))
  let dayDiff = Map.keys $ Map.differenceWith (\a b -> if a == b then Nothing else Just a) rdays ldays

  traverse_ (doDay db) dayDiff
  logInfo "Backfill complete"

    where
      remoteDays :: (MonadLogger m, MonadIO m) => m (Maybe (Map String Int))
      remoteDays = decode <$> MQTTRPC.call mc (topic "days") ""

      remoteDay :: (MonadLogger m, MonadIO m) => BL.ByteString -> m (Maybe (Set UTCTime))
      remoteDay d = decode <$> MQTTRPC.call mc (topic "day") d

      Just tbase = mkTopic . dropWhileEnd (== '/') . dropWhileEnd (/= '/') . unFilter $ dfilter
      topic = ((tbase <> "in") <>)
      doDay db d = do
        logInfo $ mconcat ["Backfilling ", pack d]
        (Just rday, lday) <- concurrently (remoteDay (BC.pack d)) (Set.fromList <$> liftIO (DB.listDay db d))
        let missing = Set.difference rday lday
            extra = Set.difference lday rday
        logDbg $ mconcat ["missing: ", lstr missing]
        logDbg $ mconcat ["extra: ", lstr extra]

        mapConcurrently_ doOne missing

      doOne ts = do
        let (Just k) = (inner . encode) ts
        logDbg $ mconcat ["Fetching remote data from ", lstr ts]
        vd <- MQTTRPC.call mc (topic "fetch") k
        logData vd
        tryInsert vd

          where inner = BL.stripPrefix "\"" <=< BL.stripSuffix "\""

run :: Options -> IO ()
run opts@Options{..} = SQLite.withConnection optDBPath $ \db -> do
  flip runReaderT (SQLiteEnv db) . runStderrLoggingT . logfilt $ withRunInIO $ \unl -> storeThings unl db

  where
    logfilt = filterLogger (\_ -> flip (if optVerbose then (>=) else (>)) LevelDebug)

    sink unl _ _ m _ = do
      tz <- getCurrentTimeZone
      let lt = utcToLocalTime tz . teslaTS $ m
      unl $ do
        logDbg $ mconcat ["Received data ", pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q %Z" lt]
        logData m
        tryInsert m

    storeThings unl db = do
      DB.dbInit db

      unl $ withMQTT opts (sink unl) $ \mc -> do
        subr <- liftIO $ subscribe mc [(optMQTTTopic, subOptions{_subQoS=QoS2,
                                                                 _retainHandling=SendOnSubscribeNew})] []
        logDbg $ mconcat ["Sub response: ", lstr subr]

        unless optNoBackfill $ backfill mc optMQTTTopic

        liftIO $ waitForClient mc

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "sink tesladb from mqtt")
