{-# LANGUAGE OverloadedStrings #-}

module Tesla.Command.Climate (
  hvacOn, hvacOff, heatSeat, Seat(..),
  setTemps, wheelHeaterOff, wheelHeaterOn
  ) where

import           Data.Char     (toLower)
import           Network.Wreq  (FormParam (..))

import           Tesla
import           Tesla.Command

-- | Turn HVAC on.
hvacOn :: AuthInfo -> VehicleID -> IO CommandResponse
hvacOn = runCmd' "command/auto_conditioning_start"

-- | Turn HVAC off.
hvacOff :: AuthInfo -> VehicleID -> IO CommandResponse
hvacOff = runCmd' "command/auto_conditioning_stop"

-- | Turn on the steering wheel heater
wheelHeater :: Bool -> AuthInfo -> VehicleID -> IO CommandResponse
wheelHeater on = runCmd "command/remote_steering_wheel_heater_request" ["on" := map toLower (show on)]

wheelHeaterOn :: AuthInfo -> VehicleID -> IO CommandResponse
wheelHeaterOn = wheelHeater True

wheelHeaterOff :: AuthInfo -> VehicleID -> IO CommandResponse
wheelHeaterOff = wheelHeater False

data Seat = DriverSeat | PassengerSeat | RearLeftSeat | RearCenterSeat | RearRightSeat

-- | Set heating levels for various seats.
heatSeat :: AuthInfo -> VehicleID -> Seat -> Int -> IO CommandResponse
heatSeat ai vid seat level = do
  runCmd "command/remote_seat_heater_request" ["heater" := seatNum seat, "level" := level] ai vid
  where
    seatNum :: Seat -> Int
    seatNum DriverSeat     = 0
    seatNum PassengerSeat  = 1
    seatNum RearLeftSeat   = 2
    seatNum RearCenterSeat = 4
    seatNum RearRightSeat  = 5

-- | Set the main HVAC temperatures.
setTemps :: AuthInfo -> VehicleID -> (Double, Double) -> IO CommandResponse
setTemps ai vid (driver, passenger) = do
  runCmd "command/set_temps" ["driver_temp" := driver, "passenger_temp" := passenger] ai vid

