module Tesla.Runner where

import           Cleff
import           Control.Concurrent       (threadDelay)
import           Control.Concurrent.Async (AsyncCancelled (..))
import           Control.Concurrent.STM   (TChan, TVar, atomically, check, dupTChan, newBroadcastTChanIO, orElse,
                                           readTChan, readTVar, registerDelay, writeTVar)
import           Control.Monad            (forever, unless, void, (>=>))
import           Control.Monad.Catch      (Exception, Handler (..), SomeException (..), catches, throwM)
import qualified Data.ByteString.Lazy     as BL
import           Data.Functor             (($>))
import           Data.Text                (Text)
import qualified Data.Text.Encoding       as TE
import           UnliftIO.Async           (async, race_, waitAnyCancel)
import           UnliftIO.Timeout         (timeout)

import           Tesla.Logging
import           Tesla.Sink
import           Tesla.Types

newtype DeathException = Die String deriving(Eq, Show)

instance Exception DeathException

data DisconnectedException = DisconnectedException deriving Show

instance Exception DisconnectedException

blToText :: BL.ByteString -> Text
blToText = TE.decodeUtf8 . BL.toStrict

textToBL :: Text -> BL.ByteString
textToBL = BL.fromStrict . TE.encodeUtf8

die :: String -> IO ()
die = throwM . Die

excLoop :: forall es. [IOE, LogFX, Sink] :>> es => Text -> Eff es () -> Eff es ()
excLoop n s = forever $ catches s [Handler cancelHandler, Handler otherHandler]

  where
    cancelHandler :: AsyncCancelled -> Eff es ()
    cancelHandler e = logError "AsyncCanceled from mqtt handler" >> throwM e

    otherHandler :: SomeException -> Eff es ()
    otherHandler e = do
      logErrorL ["Caught exception in handler: ", n, " - ", tshow e, " retrying shortly"]
      sleep 5

sleep :: MonadIO m => Int -> m ()
sleep = liftIO . threadDelay . seconds

seconds :: Int -> Int
seconds = (* 1000000)

raceABunch_ :: MonadUnliftIO m => [m a] -> m ()
raceABunch_ = traverse async >=> void.waitAnyCancel

watchdogSink :: [IOE, LogFX, Sink] :>> es => Int -> Eff es ()
watchdogSink secs = do
  tov <- liftIO $ registerDelay (seconds secs)
  again <- runAtomicSink $ \ch -> (True <$ readTChan ch) `orElse` checkTimeout tov
  logDbgL ["Watchdog returned ", tshow again]
  unless again $ liftIO $ die "Watchdog timeout"
  watchdogSink secs

    where
      checkTimeout v = (check =<< readTVar v) $> False

timeLoop :: IOE :> es => TVar Bool -> Eff es a -> (a -> Eff es Int) -> Eff es ()
timeLoop rug a p = forever (delay =<< process =<< timeout (seconds 30) a)

  where
    -- process = maybe (logError "Timed out, retrying in 60s" $> 60) p
    process = maybe (pure 60) p

    -- delay :: IOE es :> Eff es () => Int -> Eff es ()
    delay d = liftIO do
      to <- registerDelay (seconds d)
      atomically do
        v1 <- readTVar rug
        v2 <- readTVar to
        check (v1 || v2)
        writeTVar rug False

runSinks :: [IOE, LogFX] :>> es => State -> (State -> TChan Observation -> Eff es ()) -> [Eff (Sink:es) ()] -> Eff es ()
runSinks st gather sinks = do
  tch <- liftIO newBroadcastTChanIO
  race_ (gather st tch) (raceABunch_ ((\f -> runSub f =<< d tch) <$> sinks))

  where
    d = liftIO . atomically . dupTChan
    runSub f ch = runSink (SinkEnv st ch) f
