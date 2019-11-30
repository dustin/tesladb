{-# LANGUAGE OverloadedStrings #-}

module Tesla.Command.Homelink (trigger) where

import           Network.Wreq  (FormParam (..))
import           Tesla.Command

-- | Trigger nearby homelink with the given (lat,lon)
trigger :: (Double, Double) -> Car CommandResponse
trigger (lat,lon) = runCmd "flash_lights" ["lat" := lat, "lon" := lon]
