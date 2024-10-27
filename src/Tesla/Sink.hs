{-# LANGUAGE TemplateHaskell #-}

module Tesla.Sink where

import           Cleff
import           Control.Concurrent.STM   (STM, TChan, atomically)
import           Tesla.Types

data SinkEnv = SinkEnv {
  _sink_options :: State,
  _sink_chan    :: TChan Observation
}

data Sink :: Effect where
    AtomicSink :: (TChan Observation -> STM a) -> Sink m (STM a)
    SinkOption :: (State -> a) -> Sink m a

makeEffect ''Sink

runSink :: SinkEnv -> Eff (Sink : es) a -> Eff es a
runSink SinkEnv{..} = interpret \case
    AtomicSink f -> pure (f _sink_chan)
    SinkOption f -> pure (f _sink_options)

runAtomicSink :: [IOE, Sink] :>> es => (TChan Observation -> STM a) -> Eff es a
runAtomicSink f = liftIO . atomically =<< atomicSink f
