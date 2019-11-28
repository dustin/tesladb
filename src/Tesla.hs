{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Tesla
    ( authenticate, refreshAuth, AuthResponse(..), vehicles, AuthInfo(..),
      fromToken, vehicleData, VehicleData, VehicleID, vehicleURL,
      isUserPresent, isCharging, teslaTS, maybeTeslaTS,
      Door(..), OpenState(..), doors, openDoors,
      authOpts
    ) where


import           Control.Lens
import           Control.Monad          ((<=<))
import           Data.Aeson             (FromJSON (..), Options (..),
                                         Value (..), decode, defaultOptions,
                                         fieldLabelModifier, genericParseJSON)
import           Data.Aeson.Lens        (key, values, _Bool, _Integer, _String)
import qualified Data.ByteString.Char8  as BC
import qualified Data.ByteString.Lazy   as BL
import           Data.Map.Strict        (Map)
import qualified Data.Map.Strict        as Map
import           Data.Maybe             (fromJust, fromMaybe)
import           Data.Ratio
import           Data.Text              (Text)
import           Data.Time.Clock        (UTCTime)
import           Data.Time.Clock.POSIX  (posixSecondsToUTCTime)
import           Generics.Deriving.Base (Generic)
import           Network.Wreq           (FormParam (..), Options, Response,
                                         asJSON, defaults, getWith, header,
                                         postWith, responseBody)

baseURL :: String
baseURL = "https://owner-api.teslamotors.com/"
authURL :: String
authURL = baseURL <> "oauth/token"
authRefreshURL :: String
authRefreshURL = baseURL <> "oauth/token"
vehiclesURL :: String
vehiclesURL = baseURL <> "api/1/vehicles"

type VehicleID = String

vehicleURL :: VehicleID -> String -> String
vehicleURL vid c = mconcat [baseURL, "api/1/vehicles/", vid, "/", c]

userAgent :: BC.ByteString
userAgent = "github.com/dustin/tesladb 0.1"

defOpts :: Network.Wreq.Options
defOpts = defaults & header "User-Agent" .~ [userAgent]

data AuthInfo = AuthInfo {
  _clientID       :: String
  , _clientSecret :: String
  , _email        :: String
  , _password     :: String
  , _bearerToken  :: String
  } deriving(Show)

fromToken :: String -> AuthInfo
fromToken t = AuthInfo{_bearerToken=t, _clientID="", _clientSecret="", _email="", _password=""}

jsonOpts :: Data.Aeson.Options
jsonOpts = defaultOptions {
  fieldLabelModifier = dropWhile (== '_')
  }

data AuthResponse = AuthResponse {
  _access_token    :: String
  , _expires_in    :: Int
  , _refresh_token :: String
  } deriving(Generic, Show)

instance FromJSON AuthResponse where
  parseJSON = genericParseJSON jsonOpts

authenticate :: AuthInfo -> IO AuthResponse
authenticate AuthInfo{..} = do
  r <- asJSON =<< postWith defOpts authURL ["grant_type" := ("password" :: String),
                                            "client_id" := _clientID,
                                            "client_secret" := _clientSecret,
                                            "email" := _email,
                                            "password" := _password] :: IO (Response AuthResponse)
  pure $ r ^. responseBody

refreshAuth :: AuthInfo -> AuthResponse -> IO AuthResponse
refreshAuth AuthInfo{..} AuthResponse{..} = do
  r <- asJSON =<< postWith defOpts authRefreshURL ["grant_type" := ("refresh_token" :: String),
                                                   "client_id" := _clientID,
                                                   "client_secret" := _clientSecret,
                                                   "refresh_token" := _refresh_token] :: IO (Response AuthResponse)
  pure $ r ^. responseBody


authOpts :: AuthInfo -> Network.Wreq.Options
authOpts AuthInfo{..} = defOpts & header "Authorization" .~ ["Bearer " <> BC.pack _bearerToken]

-- Vehicle name -> vehicle ID
vehicles :: AuthInfo -> IO (Map Text Text)
vehicles ai = do
  r <- asJSON =<< getWith (authOpts ai) vehiclesURL :: IO (Response Value)
  let vals = r ^.. responseBody . key "response" . values . key "id_s" . _String
      keys = r ^.. responseBody . key "response" . values . key "display_name" . _String
  pure (Map.fromList $ zip keys vals)

type VehicleData = BL.ByteString

vehicleData :: AuthInfo -> VehicleID -> IO VehicleData
vehicleData ai vid = do
  r <- getWith (authOpts ai) (vehicleURL vid "vehicle_data")
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
