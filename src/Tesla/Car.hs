{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Tesla.Car (vehicleData, VehicleData, VehicleID, vehicleURL,
      isUserPresent, isCharging, teslaTS, maybeTeslaTS,
      Car, runCar, runNamedCar, authInfo, vehicleID,
      Door(..), OpenState(..), doors, openDoors) where

import           Control.Lens
import           Control.Monad          ((<=<))
import           Control.Monad.IO.Class (MonadIO (..))
import           Control.Monad.Reader   (ReaderT (..), asks, runReaderT)
import           Data.Aeson             (Value (..), decode)
import           Data.Aeson.Lens        (key, _Bool, _Integer)
import qualified Data.ByteString.Lazy   as BL
import qualified Data.Map.Strict        as Map
import           Data.Maybe             (fromJust, fromMaybe)
import           Data.Ratio
import           Data.Text              (Text, unpack)
import           Data.Time.Clock        (UTCTime)
import           Data.Time.Clock.POSIX  (posixSecondsToUTCTime)
import           Network.Wreq           (getWith, responseBody)

import           Tesla

vehicleURL :: VehicleID -> String -> String
vehicleURL v c = mconcat [baseURL, "api/1/vehicles/", v, "/", c]

type VehicleID = String

data CarEnv = CarEnv {
  _authInfo :: AuthInfo,
  _vid      :: VehicleID
  }

authInfo :: Car AuthInfo
authInfo = asks _authInfo

vehicleID :: Car VehicleID
vehicleID = asks _vid

type Car = ReaderT CarEnv IO

runCar :: AuthInfo -> VehicleID -> Car a -> IO a
runCar ai vi f = runReaderT f (CarEnv ai vi)

runNamedCar :: Text -> AuthInfo -> Car a -> IO a
runNamedCar name ai f = do
  vs <- vehicles ai
  runCar ai (unpack $ vs Map.! name) f

type VehicleData = BL.ByteString

vehicleData :: Car VehicleData
vehicleData = do
  a <- authInfo
  v <- vehicleID
  r <- liftIO $ getWith (authOpts a) (vehicleURL v "vehicle_data")
  pure . fromJust . inner $ r ^. responseBody
    where inner = BL.stripPrefix "{\"response\":" <=< BL.stripSuffix "}"

maybeVal :: VehicleData -> Maybe Value
maybeVal = decode

isUserPresent :: VehicleData -> Bool
isUserPresent b = let mb = maybeVal b ^? _Just . key "vehicle_state" . key "is_user_present" . _Bool in
                    fromMaybe False mb

isCharging :: VehicleData -> Bool
isCharging b = let mi = maybeVal b ^? _Just . key "charge_state" . key "charger_power" . _Integer in
                 fromMaybe 0 mi > 0

maybeTeslaTS :: VehicleData -> Maybe UTCTime
maybeTeslaTS b = pt <$> mv
  where mv = maybeVal b ^? _Just . key "vehicle_state" . key "timestamp" . _Integer
        pt x = posixSecondsToUTCTime . fromRational $ x % 1000

teslaTS :: VehicleData -> UTCTime
teslaTS b = maybe (error . show $ b) id . maybeTeslaTS $ b

data Door = DriverFront
          | DriverRear
          | PassengerFront
          | PassengerRear
          | FrontTrunk
          | RearTrunk
          deriving (Show, Bounded, Enum, Eq)

-- I only care about 0, but these are the observed values:
-- 0 or 1 for df
-- 0 or 2 for pf
-- 0 or 4 for dr
-- 0 or 8 for pr
-- 0 or 16 for ft
-- 0 or 32 for rt
data OpenState a = Closed a | Open a deriving (Show, Eq)

isOpen :: OpenState a -> Bool
isOpen (Closed _) = False
isOpen _          = True

fromOpenState :: OpenState a -> a
fromOpenState (Open d)   = d
fromOpenState (Closed d) = d

doors :: VehicleData -> Maybe [OpenState Door]
doors b = traverse ds $ zip ["df", "dr", "pf", "pr", "ft", "rt"] [minBound..]
  where
    ds (k,d) = c d <$> maybeVal b ^? _Just . key "vehicle_state" . key k . _Integer
    c d 0 = Closed d
    c d _ = Open   d

openDoors :: VehicleData -> [Door]
openDoors b = fromMaybe [] $ (map fromOpenState . filter isOpen <$> doors b)
