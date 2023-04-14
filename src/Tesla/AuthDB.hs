{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE OverloadedStrings #-}

module Tesla.AuthDB (updateAuth, loadAuth, loadAuthInfo) where

import           Database.SQLite.Simple hiding (bind, close)

import           Tesla.Auth             (AuthInfo (..), AuthResponse (..), fromToken)

instance ToRow AuthResponse where
  toRow (AuthResponse tok expiry refresh) = toRow (tok, refresh, expiry)

instance FromRow AuthResponse where
  fromRow = AuthResponse <$> field <*> field <*> field

updateAuth :: FilePath -> AuthResponse -> IO ()
updateAuth dbPath ar = withConnection dbPath $ \db -> do
  execute_ db "create table if not exists authinfo (ts datetime, access_token varchar, refresh_token varchar, expires_in int)"
  withTransaction db $ do
    execute_ db "delete from authinfo"
    execute db "insert into authinfo(ts, access_token, refresh_token, expires_in) values(current_timestamp, ?, ?, ?)" ar

loadAuth :: FilePath -> IO AuthResponse
loadAuth dbPath = withConnection dbPath $ \db ->
  head <$> query_ db "select access_token, expires_in, refresh_token from authinfo"

loadAuthInfo :: FilePath -> IO AuthInfo
loadAuthInfo p = fromToken . _access_token <$> loadAuth p
