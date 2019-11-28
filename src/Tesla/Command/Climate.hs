{-# LANGUAGE OverloadedStrings #-}

module Tesla.Command.Climate (
  hvacOn, hvacOff, heatSeat, Seat(..),
  setTemps, wheelHeaterOff, wheelHeaterOn
  ) where

import           Data.Char     (toLower)
import           Network.Wreq  (FormParam (..))

import           Tesla.Command

-- | Turn HVAC on.
hvacOn :: Command CommandResponse
hvacOn = runCmd' "command/auto_conditioning_start"

-- | Turn HVAC off.
hvacOff :: Command CommandResponse
hvacOff = runCmd' "command/auto_conditioning_stop"

-- | Turn on the steering wheel heater
wheelHeater :: Bool -> Command CommandResponse
wheelHeater on = runCmd "command/remote_steering_wheel_heater_request" ["on" := map toLower (show on)]

wheelHeaterOn :: Command CommandResponse
wheelHeaterOn = wheelHeater True

wheelHeaterOff :: Command CommandResponse
wheelHeaterOff = wheelHeater False

data Seat = DriverSeat | PassengerSeat | RearLeftSeat | RearCenterSeat | RearRightSeat

-- | Set heating levels for various seats.
heatSeat :: Seat -> Int -> Command CommandResponse
heatSeat seat level = do
  runCmd "command/remote_seat_heater_request" ["heater" := seatNum seat, "level" := level]
  where
    seatNum :: Seat -> Int
    seatNum DriverSeat     = 0
    seatNum PassengerSeat  = 1
    seatNum RearLeftSeat   = 2
    seatNum RearCenterSeat = 4
    seatNum RearRightSeat  = 5

-- | Set the main HVAC temperatures.
setTemps :: (Double, Double) -> Command CommandResponse
setTemps (driver, passenger) = do
  runCmd "command/set_temps" ["driver_temp" := driver, "passenger_temp" := passenger]

