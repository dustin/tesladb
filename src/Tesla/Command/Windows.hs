{-# LANGUAGE OverloadedStrings #-}

module Tesla.Command.Windows (
  ventWindows, closeWindows
  ) where

import           Data.Text     (Text)
import           Network.Wreq  (FormParam (..))
import           Tesla.Command

windowControl :: Text -> (Double, Double) -> Car CommandResponse
windowControl x (lat,lon) = runCmd "window_control" [ "command" := x, "lat" := lat, "lon" := lon]

ventWindows :: Car CommandResponse
ventWindows = windowControl "vent" (0,0)

closeWindows :: (Double, Double) -> Car CommandResponse
closeWindows = windowControl "close"
