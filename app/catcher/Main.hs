{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}

module Main where

import           Control.Monad                        (unless, (<=<))
import qualified Control.Monad.Catch                  as E
import           Control.Monad.IO.Class               (MonadIO (..))
import           Control.Monad.IO.Unlift              (MonadUnliftIO, withRunInIO)
import           Control.Monad.Logger                 (LogLevel (..), LoggingT, MonadLogger, filterLogger,
                                                       logWithoutLoc, runStderrLoggingT)
import           Control.Monad.Reader                 (MonadReader, ReaderT, asks, runReaderT)
import           Data.Aeson                           (decode, encode)
import qualified Data.ByteString.Char8                as BCS
import qualified Data.ByteString.Lazy                 as BL
import qualified Data.ByteString.Lazy.Char8           as BC
import           Data.Foldable                        (fold, traverse_)
import           Data.List                            (intercalate, sortOn)
import           Data.Map.Strict                      (Map)
import qualified Data.Map.Strict                      as Map
import           Data.Maybe                           (fromJust)
import           Data.Set                             (Set)
import qualified Data.Set                             as Set
import           Data.Text                            (Text, dropWhileEnd, pack)
import qualified Data.Text.Encoding                   as TE
import           Data.Time.Clock                      (UTCTime)
import           Data.Time.Format                     (defaultTimeLocale, formatTime)
import           Data.Time.LocalTime                  (getCurrentTimeZone, utcToLocalTime)
import           Data.Word                            (Word32)
import qualified Database.PostgreSQL.Simple           as PG
import qualified Database.SQLite.Simple               as SQLite
import           Network.MQTT.Client
import qualified Network.MQTT.RPC                     as MQTTRPC
import           Network.MQTT.Topic
import           Network.MQTT.Types                   (RetainHandling (..))
import           Network.URI
import           Options.Applicative                  (Parser, auto, eitherReader, execParser, fullDesc, help, helper,
                                                       info, long, maybeReader, option, progDesc, short, showDefault,
                                                       strOption, switch, value, (<**>))
import           Options.Applicative.Help.Levenshtein (editDistance)
import           UnliftIO.Async                       (concurrently, mapConcurrently_)

import           Tesla.Car
import qualified Tesla.PostgresDB                     as PDB
import qualified Tesla.SqliteDB                       as SDB

data DBType = DBSQLite | DBPostgres deriving Eq

instance Show DBType where
  show DBSQLite   = "sqlite"
  show DBPostgres = "postgres"

data Options = Options {
  optDBPath         :: String
  , optMQTTURI      :: URI
  , optMQTTTopic    :: Filter
  , optNoBackfill   :: Bool
  , optSessionTime  :: Word32
  , optCleanSession :: Bool
  , optVerbose      :: Bool
  , optDBType       :: DBType
  }

class MonadIO m => Persistence m where
  dbInit :: m ()
  listDays :: m [(String,Int)]
  listDay  :: String -> m [UTCTime]
  insertVData :: VehicleData -> m ()

newtype SQLiteEnv = SQLiteEnv {
  sqliteConn :: SQLite.Connection
  }

newtype SQLiteP a = SqliteP {
  runSQLiteP :: ReaderT SQLiteEnv (LoggingT IO) a }
                deriving (Applicative, Functor, Monad, MonadIO, MonadLogger, MonadFail,
                          E.MonadThrow, E.MonadCatch, E.MonadMask, MonadUnliftIO,
                          MonadReader SQLiteEnv)

instance Persistence SQLiteP where
  dbInit = asks sqliteConn >>= liftIO . SDB.dbInit
  listDays = asks sqliteConn >>= liftIO . SDB.listDays
  listDay d = asks sqliteConn >>= \db -> liftIO $ SDB.listDay db d
  insertVData d = asks sqliteConn >>= \db -> liftIO $ SDB.insertVData db d

newtype PGEnv = PGEnv {
  pgConn :: PG.Connection
  }

newtype PostgresP a = PostgresP {
  runPG :: ReaderT PGEnv (LoggingT IO) a }
                    deriving (Applicative, Functor, Monad, MonadIO, MonadLogger, MonadFail,
                              E.MonadThrow, E.MonadCatch, E.MonadMask, MonadUnliftIO,
                              MonadReader PGEnv)

instance Persistence PostgresP where
  dbInit = asks pgConn >>= liftIO . PDB.dbInit
  listDays = asks pgConn >>= liftIO . PDB.listDays
  listDay d = asks pgConn >>= \db -> liftIO $ PDB.listDay db d
  insertVData d = asks pgConn >>= \db -> liftIO $ PDB.insertVData db d

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
  <*> option dbtype (short 'd' <> long "db type" <> showDefault
                     <> value DBSQLite <> help "database type")

  where
    dbs = [("sqlite", DBSQLite),
            ("postgres", DBPostgres)]
    dbtype = eitherReader $ \s -> maybe (Left (inv "db type" s (fst <$> dbs))) Right $ lookup s dbs
    bestMatch n = head . sortOn (editDistance n)
    inv t v vs = fold ["invalid ", t, ": ", show v, ", perhaps you meant: ", bestMatch v vs,
                        "\nValid values:  ", intercalate ", " vs]


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

tryInsert :: (Persistence m, MonadLogger m, E.MonadCatch m, MonadIO m)
          => VehicleData -> m ()
tryInsert vd = E.catches (insertVData vd) [
  E.Handler (\ex -> report (ex :: SQLite.SQLError)),
  E.Handler (\ex -> report (ex :: PG.SqlError))
  ]
  where report es = logErr $ mconcat ["Error on ", lstr . maybeTeslaTS $ vd, ": ", lstr es]

backfill :: (Persistence m, MonadLogger m, E.MonadCatch m, MonadFail m, MonadUnliftIO m)
         => MQTTClient -> Filter -> m ()
backfill mc dfilter = do
  logInfo "Beginning backfill"
  (Just rdays, ldays) <- concurrently remoteDays (Map.fromList <$> listDays)
  let dayDiff = Map.keys $ Map.differenceWith (\a b -> if a == b then Nothing else Just a) rdays ldays

  traverse_ doDay dayDiff
  logInfo "Backfill complete"

    where
      remoteDays :: (MonadLogger m, MonadIO m) => m (Maybe (Map String Int))
      remoteDays = decode <$> MQTTRPC.call mc (topic "days") ""

      remoteDay :: (MonadLogger m, MonadIO m) => BL.ByteString -> m (Maybe (Set UTCTime))
      remoteDay d = decode <$> MQTTRPC.call mc (topic "day") d

      Just tbase = mkTopic . dropWhileEnd (== '/') . dropWhileEnd (/= '/') . unFilter $ dfilter
      topic = ((tbase <> "in") <>)
      doDay d = do
        logInfo $ mconcat ["Backfilling ", pack d]
        (Just rday, lday) <- concurrently (remoteDay (BC.pack d)) (Set.fromList <$> listDay d)
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

storeThings :: (Persistence m, E.MonadMask m, MonadLogger m, MonadFail m, MonadUnliftIO m)
            => Options -> (m () -> IO ()) -> IO ()
storeThings opts@Options{..} unl = do
  unl dbInit

  unl $ withMQTT opts sink $ \mc -> do
    subr <- liftIO $ subscribe mc [(optMQTTTopic, subOptions{_subQoS=QoS2,
                                                             _retainHandling=SendOnSubscribeNew})] []
    logDbg $ mconcat ["Sub response: ", lstr subr]

    unless optNoBackfill $ backfill mc optMQTTTopic

    liftIO $ waitForClient mc

      where
        sink _ _ m _ = do
          tz <- getCurrentTimeZone
          let lt = utcToLocalTime tz . teslaTS $ m
          unl $ do
            logDbg $ mconcat ["Received data ", pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q %Z" lt]
            logData m
            tryInsert m

run :: Options -> IO ()
run opts@Options{..} = runDB optDBType
  where
    runDB DBSQLite   = runSQLite $ withRunInIO (\a -> storeThings opts a)
    runDB DBPostgres = runPostgres $ withRunInIO (\a -> storeThings opts a)
    runSQLite a = SQLite.withConnection optDBPath $ \db -> runEnv runSQLiteP (SQLiteEnv db) $ a
    runPostgres a = PDB.withDB (BCS.pack optDBPath) $ \db -> runEnv runPG (PGEnv db) $ a

    runEnv :: MonadIO m => (t -> ReaderT r (LoggingT m) a) -> r -> t -> m a
    runEnv runp e m = runStderrLoggingT . logfilt $ runReaderT (runp m) e
      where
        logfilt = filterLogger (\_ -> flip (if optVerbose then (>=) else (>)) LevelDebug)

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "sink tesladb from mqtt")
