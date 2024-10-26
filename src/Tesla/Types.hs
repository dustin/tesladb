module Tesla.Types where

import           Data.Aeson          (Value)
import           Data.Text           (Text)
import           Network.MQTT.Client
import           Network.MQTT.Topic
import           Network.URI
import           UnliftIO            (TVar)

import           Tesla.Car           (VehicleData)

data Options = Options {
  optDBPath        :: FilePath
  , optVName       :: Text
  , optNoMQTT      :: Bool
  , optVerbose     :: Bool
  , optMQTTURI     :: URI
  , optMQTTTopic   :: Topic
  , optInTopic     :: Filter
  , optCMDsEnabled :: Bool
  , optMQTTProds   :: Topic
  }

data PrereqAction = CheckAwake | CheckAsleep deriving (Show, Eq)

data State = State {
  opts      :: Options
  , prereq  :: TVar PrereqAction
  , loopRug :: TVar Bool
  }

data Observation = VData VehicleData | PData Value
