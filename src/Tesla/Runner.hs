{-# LANGUAGE OverloadedStrings #-}

module Tesla.Runner where

import           Control.Concurrent       (threadDelay)
import           Control.Concurrent.Async (AsyncCancelled (..))
import           Control.Concurrent.STM   (TChan, atomically, orElse, readTChan, readTVar, registerDelay, retry)
import           Control.Monad            (forever, unless, void)
import           Control.Monad.Catch      (Exception, Handler (..), MonadCatch, SomeException (..), catches, throwM)
import           Control.Monad.IO.Class   (MonadIO (..))
import           Control.Monad.IO.Unlift  (MonadUnliftIO)
import           Control.Monad.Logger     (LoggingT, MonadLogger, logDebugN, logErrorN, logInfoN)
import           Control.Monad.Reader     (ReaderT, asks)
import qualified Data.ByteString.Lazy     as BL
import           Data.Text                (Text)
import qualified Data.Text                as T
import qualified Data.Text.Encoding       as TE
import           UnliftIO.Async           (async, waitAnyCancel)

data SinkEnv o a = SinkEnv {
  _sink_options :: o,
  _sink_chan    :: TChan a
  }

type Sink o a = ReaderT (SinkEnv o a) (LoggingT IO)

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

logErr :: MonadLogger m => Text -> m ()
logErr = logErrorN

logInfo :: MonadLogger m => Text -> m ()
logInfo = logInfoN

logDbg :: MonadLogger m => Text -> m ()
logDbg = logDebugN

tshow :: Show a => a -> Text
tshow = T.pack . show

excLoop :: Text -> (Sink o a) () -> (Sink o a) ()
excLoop n s = forever $ catches s [Handler cancelHandler, Handler otherHandler]

  where
    cancelHandler :: (MonadCatch m, MonadLogger m, MonadIO m) => AsyncCancelled -> m ()
    cancelHandler e = logErr "AsyncCanceled from mqtt handler" >> throwM e

    otherHandler :: (MonadCatch m, MonadLogger m, MonadIO m) => SomeException -> m ()
    otherHandler e = do
      logErr $ mconcat ["Caught exception in handler: ", n, " - ", tshow e, " retrying shortly"]
      sleep 5

sleep :: MonadIO m => Int -> m ()
sleep = liftIO . threadDelay . seconds

seconds :: Int -> Int
seconds = (* 1000000)

raceABunch_ :: MonadUnliftIO m => [m a] -> m ()
raceABunch_ is = traverse async is >>= void.waitAnyCancel

watchdogSink :: Int -> (Sink o a) ()
watchdogSink secs = do
  ch <- asks _sink_chan
  tov <- liftIO $ registerDelay (seconds secs)
  again <- liftIO $ atomically $ (True <$ readTChan ch) `orElse` checkTimeout tov
  logDbg $ "Watchdog returned " <> tshow again
  unless again $ liftIO $ die "Watchdog timeout"
  watchdogSink secs

    where
      checkTimeout v = do
        v' <- readTVar v
        unless v' retry
        pure False
