{-# LANGUAGE OverloadedStrings #-}

module Tesla.Command.Climate (
  hvacOn, hvacOff, heatSeat, Seat(..),
  setTemps, wheelHeater, wheelHeaterOff, wheelHeaterOn
  ) where

import           Data.Char     (toLower)
import           Network.Wreq  (FormParam (..))

import           Tesla.Command

-- | Turn HVAC on.
hvacOn :: Car CommandResponse
hvacOn = runCmd' "auto_conditioning_start"

-- | Turn HVAC off.
hvacOff :: Car CommandResponse
hvacOff = runCmd' "auto_conditioning_stop"

-- | Turn on the steering wheel heater
wheelHeater :: Bool -> Car CommandResponse
wheelHeater on = runCmd "remote_steering_wheel_heater_request" ["on" := map toLower (show on)]

wheelHeaterOn :: Car CommandResponse
wheelHeaterOn = wheelHeater True

wheelHeaterOff :: Car CommandResponse
wheelHeaterOff = wheelHeater False

data Seat = DriverSeat | PassengerSeat | RearLeftSeat | RearCenterSeat | RearRightSeat

-- | Set heating levels for various seats.
heatSeat :: Seat -> Int -> Car CommandResponse
heatSeat seat level = do
  runCmd "remote_seat_heater_request" ["heater" := seatNum seat, "level" := level]
  where
    seatNum :: Seat -> Int
    seatNum DriverSeat     = 0
    seatNum PassengerSeat  = 1
    seatNum RearLeftSeat   = 2
    seatNum RearCenterSeat = 4
    seatNum RearRightSeat  = 5

-- | Set the main HVAC temperatures.
setTemps :: (Double, Double) -> Car CommandResponse
setTemps (driver, passenger) = do
  runCmd "set_temps" ["driver_temp" := driver, "passenger_temp" := passenger]

