{-# LANGUAGE TemplateHaskell #-}

module Tesla.MQTTFX where

import           Cleff
import           Control.Concurrent.STM (STM)
import           Data.ByteString.Lazy   (ByteString)
import           Data.Word              (Word32)
import           Network.MQTT.Client    (MQTTClient, Property (..), QoS (..), Topic, publishq)

type Seconds = Word32

data MQTTFX :: Effect where
    -- | If seconds is 0, we don't retain.  If it's > 0, we retain for this long.
    PublishMQTT :: Topic -> Seconds -> ByteString -> [Property] -> MQTTFX m ()
    -- | We have a case where we need to mix some STM with MQTT client STM ops.
    AtomicMQTT :: (MQTTClient -> STM a) -> MQTTFX m (STM a)

makeEffect ''MQTTFX

runMQTT :: (IOE :> es) => MQTTClient -> Eff (MQTTFX : es) a -> Eff es a
runMQTT mc = interpret \case
    PublishMQTT topic 0 payload props -> liftIO $ publishq mc topic payload False QoS2 props
    PublishMQTT topic secs payload props -> liftIO $ publishq mc topic payload False QoS2 (
        PropMessageExpiryInterval secs : props)
    AtomicMQTT f -> pure (f mc)

-- | Common mechanism to publish a retained JSON message.
publishRetained :: MQTTFX :> es => Topic -> Seconds -> ByteString -> Eff es ()
publishRetained topic secs payload = publishMQTT topic secs payload [PropContentType "application/json"]

-- | Common mechanism to publish a non-retained JSON message.
publishEphemeral :: MQTTFX :> es => Topic -> ByteString -> Eff es ()
publishEphemeral topic payload = publishMQTT topic 0 payload [PropContentType "application/json"]
