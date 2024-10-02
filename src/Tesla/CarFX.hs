{-# LANGUAGE TemplateHaskell #-}

module Tesla.CarFX where

import           Cleff
import           Tesla.AuthDB
import qualified Tesla.Car    as Car
import           Tesla.Car    (Car, VehicleID)

data CarFX :: Effect where
    CurrentVehicle :: CarFX m VehicleID
    RunCar :: (Car IO a) -> CarFX m a

makeEffect ''CarFX

runCarFX :: (IOE :> es) => FilePath -> VehicleID -> Eff (CarFX : es) a -> Eff es a
runCarFX dbPath vid = interpret \case
    CurrentVehicle -> pure vid
    RunCar a       -> liftIO $ Car.runCar (loadAuthInfo dbPath) vid a
