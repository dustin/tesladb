{-# LANGUAGE OverloadedStrings #-}

module Tesla.Command.Alerts (
  honkHorn, flashLights
  ) where

import           Tesla.Command

honkHorn :: Car CommandResponse
honkHorn = runCmd' "honk_horn"

flashLights :: Car CommandResponse
flashLights = runCmd' "flash_lights"
