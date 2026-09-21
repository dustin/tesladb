{-# LANGUAGE TemplateHaskell #-}

module Tesla.CarFX where

import           Effectful                  (Dispatch (Dynamic), DispatchOf,
                                             Eff, Effect, IOE, withRunInIO,
                                             (:>))
import           Effectful.Dispatch.Dynamic (interpret_)
import           Effectful.TH               (makeEffect)
import qualified Tesla.Car                  as Car
import           Tesla.Car                  (Car, VehicleID)
import           Tesla.DB

data CarFX :: Effect where
    CurrentVehicle :: CarFX m VehicleID
    RunCar :: (Car IO a) -> CarFX m a

type instance DispatchOf CarFX = Dynamic

makeEffect ''CarFX

runCarFX :: (IOE :> es, DB :> es) => VehicleID -> Eff (CarFX : es) a -> Eff es a
runCarFX vid = interpret_ \case
    CurrentVehicle -> pure vid
    RunCar a       -> withRunInIO $ \unl -> Car.runCar (unl loadAuthInfo) vid a
