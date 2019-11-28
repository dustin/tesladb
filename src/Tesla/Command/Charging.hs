{-# LANGUAGE OverloadedStrings #-}

module Tesla.Command.Charging (
  startCharging, stopCharging, setLimit
  ) where

import           Network.Wreq  (FormParam (..))

import           Tesla.Command

startCharging :: Car CommandResponse
startCharging = runCmd' "charge_start"

stopCharging :: Car CommandResponse
stopCharging = runCmd' "charge_stop"

setLimit :: Int -> Car CommandResponse
setLimit to = runCmd "set_charge_limit" ["percent" := to ]
