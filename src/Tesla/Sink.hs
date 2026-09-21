{-# LANGUAGE TemplateHaskell #-}

module Tesla.Sink where

import           Control.Concurrent.STM     (STM, TChan, atomically)
import           Effectful                  (Dispatch (Dynamic), DispatchOf,
                                             Eff, Effect, IOE, liftIO, (:>))
import           Effectful.Dispatch.Dynamic (interpret_)
import           Effectful.TH               (makeEffect)
import           Tesla.Types

data SinkEnv = SinkEnv {
  _sink_options :: State,
  _sink_chan    :: TChan Observation
}

data Sink :: Effect where
    AtomicSink :: (TChan Observation -> STM a) -> Sink m (STM a)
    SinkOption :: (State -> a) -> Sink m a

type instance DispatchOf Sink = Dynamic

makeEffect ''Sink

runSink :: SinkEnv -> Eff (Sink : es) a -> Eff es a
runSink SinkEnv{..} = interpret_ \case
    AtomicSink f -> pure (f _sink_chan)
    SinkOption f -> pure (f _sink_options)

runAtomicSink :: (IOE :> es, Sink :> es) => (TChan Observation -> STM a) -> Eff es a
runAtomicSink f = liftIO . atomically =<< atomicSink f
