{-# LANGUAGE TemplateHaskell #-}

module Tesla.DB where

import           Cleff
import           Data.Time.Clock (UTCTime)
import           Tesla.Auth      (AuthInfo (..), AuthResponse (..), fromToken)
import           Tesla.Car       (VehicleData)

data DB :: Effect where
    InitDB :: DB m ()
    InsertVData :: VehicleData -> DB m ()
    ListDays :: DB m [(String,Int)]
    ListDay :: String -> DB m [UTCTime]
    FetchDatum :: UTCTime -> DB m VehicleData

    UpdateAuth :: AuthResponse -> DB m ()
    LoadAuth :: DB m AuthResponse

makeEffect ''DB

loadAuthInfo :: [IOE, DB] :>> es => Eff es AuthInfo
loadAuthInfo = fromToken . _access_token <$> loadAuth
