module Tesla.Runner where

import           Cleff
import           Cleff.Reader
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
import           Tesla.Types
import           UnliftIO.Async           (async, race_, waitAnyCancel)
import           UnliftIO.Timeout         (timeout)

import           Tesla.Logging

data SinkEnv = SinkEnv {
  _sink_options :: State,
  _sink_chan    :: TChan Observation
}

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

excLoop :: forall es. [IOE, LogFX, Reader SinkEnv] :>> es => Text -> Eff es () -> Eff es ()
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

watchdogSink :: [IOE, LogFX, Reader SinkEnv] :>> es => Int -> Eff es ()
watchdogSink secs = do
  ch <- asks _sink_chan
  tov <- liftIO $ registerDelay (seconds secs)
  again <- liftIO $ atomically $ (True <$ readTChan ch) `orElse` checkTimeout tov
  logDbgL ["Watchdog returned ", tshow again]
  unless again $ liftIO $ die "Watchdog timeout"
  watchdogSink secs

    where
      checkTimeout v = (check =<< readTVar v) $> False

-- timeLoop :: ([IOE, LogFX] :>> es, MonadUnliftIO m) => TVar Bool -> m t -> (t -> m Int) -> Eff es ()
timeLoop :: MonadUnliftIO m => TVar Bool -> m a -> (a -> m Int) -> m b
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

runSinks :: [IOE, LogFX] :>> es => State -> (State -> TChan Observation -> Eff es ()) -> [Eff (Reader SinkEnv:es) ()] -> Eff es ()
runSinks st gather sinks = do
  tch <- liftIO newBroadcastTChanIO
  race_ (gather st tch) (raceABunch_ ((\f -> runSink f =<< d tch) <$> sinks))

  where
    d = liftIO . atomically . dupTChan
    runSink f ch = runReader (SinkEnv st ch) f
