module Main where

import           Cleff
import           Cleff.Fail
import           Cleff.Mask
import           Control.Monad              (unless, (<=<))
import           Control.Monad.Catch        (SomeException (..), try)
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
import           Network.MQTT.Client
import qualified Network.MQTT.RPC           as MQTTRPC
import           Network.MQTT.Topic
import           Network.MQTT.Types         (RetainHandling (..))
import           Network.URI
import           Options.Applicative        (Parser, auto, execParser, fullDesc, help, helper, info, long, maybeReader,
                                             option, progDesc, short, showDefault, strOption, switch, value, (<**>))
import           UnliftIO.Async             (concurrently, mapConcurrently_)

import           Tesla.Car
import           Tesla.DB
import           Tesla.Logging
import           Tesla.RunDB

data Options = Options {
  optDBPath         :: String
  , optMQTTURI      :: URI
  , optMQTTTopic    :: Filter
  , optNoBackfill   :: Bool
  , optSessionTime  :: Word32
  , optCleanSession :: Bool
  , optVerbose      :: Bool
  }

blToText :: BL.ByteString -> Text
blToText = TE.decodeUtf8 . BL.toStrict

lstr :: Show a => a -> Text
lstr = pack . show

options :: Parser Options
options = Options
  <$> strOption (long "dbpath" <> showDefault <> value "tesla.db" <> help "tesladb path")
  <*> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> strOption (long "mqtt-topic" <> showDefault <> value "tmp/tesla" <> help "MQTT topic")
  <*> switch (long "disable-backfill" <> help "Disable backfill via MQTT")
  <*> option auto (long "session-expiry" <> showDefault <> value 3600 <> help "Session expiration")
  <*> switch (long "clean-session" <> help "Clean the MQTT session")
  <*> switch (short 'v' <> long "verbose" <> help "enable debug logging")

type Callback m = MQTTClient -> Topic -> BL.ByteString -> [Property] -> m ()

withMQTT :: [IOE, LogFX, Mask] :>> es => Options -> Callback (Eff es) -> (MQTTClient -> Eff es ()) -> Eff es ()
withMQTT Options{..} cb = bracket conn (liftIO . normalDisconnect)
  where
    conn = withRunInIO $ \unl -> do
      mc <- connectURI mqttConfig{_cleanSession=optSessionTime == 0,
                                           _protocol=Protocol50,
                                           _msgCB=SimpleCallback (\mc t b props -> unl $ cb mc t b props),
                                           _connProps=[PropReceiveMaximum 65535,
                                                       PropSessionExpiryInterval optSessionTime,
                                                       PropTopicAliasMaximum 10,
                                                       PropRequestResponseInformation 1,
                                                       PropRequestProblemInformation 1]}
            optMQTTURI
      ack <- connACK mc
      unl $ logDbgL ["MQTT connected: ", lstr ack]
      pure mc

logData :: LogFX :> es => VehicleData -> Eff es ()
logData vd = unless (up || null od) $ logInfoL [
  "User is not present, but the following doors are open at ", lstr ts, ": ", lstr od]
  where
    up = isUserPresent vd
    od = openDoors vd
    ts = teslaTS vd

tryInsert :: [IOE, Mask, LogFX, DB] :>> es => VehicleData -> Eff es ()
tryInsert vd = try (insertVData vd) >>= \case
  Left (e :: SomeException) -> logErrorL ["Error on ", lstr . maybeTeslaTS $ vd, ": ", lstr e]
  Right _                   -> pure ()

backfill :: forall es. [IOE, Mask, Fail, DB, LogFX] :>> es => MQTTClient -> Filter -> Eff es ()
backfill mc dfilter = do
  logInfo "Beginning backfill"
  (Just rdays, ldays) <- concurrently remoteDays (Map.fromList <$> listDays)
  let dayDiff = Map.keys $ Map.differenceWith (\a b -> if a == b then Nothing else Just a) rdays ldays

  traverse_ doDay dayDiff
  logInfo "Backfill complete"

    where
      remoteDays ::Eff es (Maybe (Map String Int))
      remoteDays = decode <$> MQTTRPC.call mc (topic "days") ""

      remoteDay :: BL.ByteString -> Eff es (Maybe (Set UTCTime))
      remoteDay d = decode <$> MQTTRPC.call mc (topic "day") d

      Just tbase = mkTopic . dropWhileEnd (== '/') . dropWhileEnd (/= '/') . unFilter $ dfilter
      topic = ((tbase <> "in") <>)
      doDay d = do
        logInfoL ["Backfilling ", pack d]
        (Just rday, lday) <- concurrently (remoteDay (BC.pack d)) (Set.fromList <$> listDay d)
        let missing = Set.difference rday lday
            extra = Set.difference lday rday
        logDbgL ["missing: ", lstr missing]
        logDbgL ["extra: ", lstr extra]

        mapConcurrently_ doOne missing

      doOne ts = do
        let (Just k) = (inner . encode) ts
        logDbgL ["Fetching remote data from ", lstr ts]
        vd <- MQTTRPC.call mc (topic "fetch") k
        logData vd
        tryInsert vd

          where inner = BL.stripPrefix "\"" <=< BL.stripSuffix "\""

storeThings :: [IOE, Mask, Fail, LogFX, Fail, DB] :>> es => Options -> Eff es ()
storeThings opts@Options{..} =
  withMQTT opts sink $ \mc -> do
    subr <- liftIO $ subscribe mc [(optMQTTTopic, subOptions{_subQoS=QoS2,
                                                             _retainHandling=SendOnSubscribeNew})] []
    logDbgL ["Sub response: ", lstr subr]

    unless optNoBackfill $ backfill mc optMQTTTopic

    liftIO $ waitForClient mc

      where
        sink _ _ m _ = do
          tz <- liftIO getCurrentTimeZone
          let lt = utcToLocalTime tz . teslaTS $ m
          logDbgL ["Received data ", pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q %Z" lt]
          logData m
          tryInsert m

run :: Options -> IO ()
run opts@Options{optDBPath, optVerbose} =
  runIOE . runFailIO . runMask . runLogFX optVerbose . withDB optDBPath $ do
    initDB
    storeThings opts

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "sink tesladb from mqtt")
