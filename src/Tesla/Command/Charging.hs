{-# LANGUAGE OverloadedStrings #-}

module Tesla.Command.Charging (
  startCharging, stopCharging, setLimit
  ) where

import           Network.Wreq  (FormParam (..))

import           Tesla.Command

startCharging :: Command CommandResponse
startCharging = runCmd' "charge_start"

stopCharging :: Command CommandResponse
stopCharging = runCmd' "charge_stop"

setLimit :: Int -> Command CommandResponse
setLimit to = runCmd "set_charge_limit" ["percent" := to ]