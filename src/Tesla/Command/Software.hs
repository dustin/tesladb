{-# LANGUAGE OverloadedStrings #-}

module Tesla.Command.Software (
  schedule, cancel
  ) where

import           Network.Wreq  (FormParam (..))

import           Tesla.Command

-- | Schedule a software update in this many seconds.
schedule :: Int -> Car CommandResponse
schedule secs = runCmd "schedule_software_update" ["offset_sec" := secs]

-- | Cancel a scheduled software update.
cancel :: Car CommandResponse
cancel = runCmd' "cancel_software_update"
