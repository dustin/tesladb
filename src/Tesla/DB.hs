{-# LANGUAGE TemplateHaskell #-}

module Tesla.DB where

import           Data.Time.Clock (UTCTime)
import           Effectful       (Dispatch (Dynamic), DispatchOf, Eff, Effect,
                                  IOE, (:>))
import           Effectful.TH    (makeEffect)
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

type instance DispatchOf DB = Dynamic

makeEffect ''DB

loadAuthInfo :: (IOE :> es, DB :> es) => Eff es AuthInfo
loadAuthInfo = fromToken . _access_token <$> loadAuth
