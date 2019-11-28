{-# LANGUAGE OverloadedStrings #-}

module Tesla.Command (runCmd, runCmd', CommandResponse, runCommands, Command) where

import           Control.Lens
import           Control.Monad.IO.Class (MonadIO (..))
import           Control.Monad.Reader   (ReaderT (..), asks, runReaderT)
import           Data.Aeson
import           Data.Aeson.Lens        (key, _Bool, _String)
import qualified Data.ByteString.Lazy   as BL
import           Data.Text              (Text)
import           Network.Wreq           (Response, asJSON, postWith,
                                         responseBody)
import           Network.Wreq.Types     (Postable)

import           Tesla

data CommandEnv = CommandEnv {
  authInfo :: AuthInfo,
  vid      :: VehicleID
  }

type Command = ReaderT CommandEnv IO

type CommandResponse = Either Text ()

-- | Run a command with a payload.
runCmd :: Postable p => String -> p -> Command CommandResponse
runCmd cmd p = do
  a <- asks authInfo
  v <- asks vid
  r <- liftIO (asJSON =<< postWith (authOpts a) (vehicleURL v $ "command/" <> cmd) p :: IO (Response Value))
  pure $ case (r ^? responseBody . key "response" . key "result" . _Bool) of
    Just True  -> Right ()
    _ -> Left $ r ^. responseBody . key "response" . key "reason" . _String

-- | run command without a payload
runCmd' :: String -> Command CommandResponse
runCmd' cmd = runCmd cmd emptyPost
  where emptyPost = "" :: BL.ByteString

runCommands :: AuthInfo -> VehicleID -> Command a -> IO a
runCommands ai vi f = runReaderT f (CommandEnv ai vi)
