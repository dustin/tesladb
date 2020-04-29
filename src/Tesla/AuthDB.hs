{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Tesla.AuthDB (updateAuth, loadAuth, loadAuthInfo) where

import           Control.Monad          (guard)
import           Database.SQLite.Simple hiding (bind, close)

import           Tesla.Auth             (AuthInfo (..), AuthResponse (..), fromToken)

createStatement :: Query
createStatement = "create table if not exists authinfo (ts, access_token, refresh_token, expires_in)"

insertStatement :: Query
insertStatement = "insert into authinfo(ts, access_token, refresh_token, expires_in) values(current_timestamp, ?, ?, ?)"

deleteStatement :: Query
deleteStatement = "delete from authinfo"

selectStatement :: Query
selectStatement = "select access_token, refresh_token, expires_in from authinfo"

updateAuth :: FilePath -> AuthResponse -> IO ()
updateAuth dbPath AuthResponse{..} = withConnection dbPath up
  where up db = do
          execute_ db createStatement
          withTransaction db $ do
            execute_ db deleteStatement
            execute db insertStatement (_access_token, _refresh_token, _expires_in)

loadAuth :: FilePath -> IO AuthResponse
loadAuth dbPath = withConnection dbPath up
  where up db = do
          rows <- query_ db selectStatement :: IO [(String, String, Int)]
          guard (length rows == 1)
          let [(_access_token, _refresh_token, _expires_in)] = rows
          pure $ AuthResponse{..}

loadAuthInfo :: FilePath -> IO AuthInfo
loadAuthInfo p = loadAuth p >>= \AuthResponse{..} -> pure $ fromToken _access_token
