{-# LANGUAGE TemplateHaskell #-}

module Tesla.CarFX where

import           Cleff
import qualified Tesla.Car as Car
import           Tesla.Car (Car, VehicleID)
import           Tesla.DB

data CarFX :: Effect where
    CurrentVehicle :: CarFX m VehicleID
    RunCar :: (Car IO a) -> CarFX m a

makeEffect ''CarFX

runCarFX :: ([IOE, DB] :>> es) => VehicleID -> Eff (CarFX : es) a -> Eff es a
runCarFX vid = interpret \case
    CurrentVehicle -> pure vid
    RunCar a       -> withRunInIO $ \unl -> Car.runCar (unl loadAuthInfo) vid a
