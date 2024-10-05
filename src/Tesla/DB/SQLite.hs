{-# OPTIONS_GHC -Wno-orphans #-}

module Tesla.DB.SQLite (runConn, runStr) where

import           Cleff
import           Control.Monad          (guard)
import           Data.Time.Clock        (UTCTime)
import           Database.SQLite.Simple hiding (bind, close)
import           Tesla.Auth             (AuthResponse (..))

import           Tesla.Car              (VehicleData, teslaTS)
import           Tesla.DB

runStr :: IOE :> es => String -> Eff (DB : es) a -> Eff es a
runStr str f = liftIO (open str) >>= flip runConn f

runConn :: (IOE :> es) => Connection -> Eff (DB : es) a -> Eff es a
runConn db = interpret \case
  InitDB            -> liftIO $ sdbInit db
  InsertVData vdata -> liftIO $ sinsertVData db vdata
  ListDays          -> liftIO $ slistDays db
  ListDay d         -> liftIO $ slistDay db d
  FetchDatum t      -> liftIO $ sfetchDatum db t
  UpdateAuth ar     -> liftIO $ supdateAuth db ar
  LoadAuth          -> liftIO $ sloadAuth db


sdbInit :: Connection -> IO ()
sdbInit db = do
  execute_ db "pragma auto_vacuum = incremental"
  execute_ db "create table if not exists data (ts timestamp, data blob)"
  execute_ db "create unique index if not exists data_ts on data(ts)"
  execute_ db "create table if not exists authinfo (ts datetime, access_token varchar, refresh_token varchar, expires_in int)"

sinsertVData :: Connection -> VehicleData -> IO ()
sinsertVData db vdata = execute db "insert into data(ts, data) values(?, ?)" (teslaTS vdata, vdata)

slistDays :: Connection -> IO [(String,Int)]
slistDays db = query_ db "select date(ts) as day, count(*) from data group by day"

slistDay :: Connection -> String -> IO [UTCTime]
slistDay db d = fmap fromOnly <$> query db "select ts from data where date(ts) = ?" (Only d)

sfetchDatum :: Connection -> UTCTime -> IO VehicleData
sfetchDatum db t = do
  rows <- query db "select data from data where ts = ?" (Only t)
  guard $ length rows == 1
  pure . fromOnly . head $ rows

instance ToRow AuthResponse where
  toRow (AuthResponse tok expiry refresh) = toRow (tok, refresh, expiry)

instance FromRow AuthResponse where
  fromRow = AuthResponse <$> field <*> field <*> field

supdateAuth :: Connection -> AuthResponse -> IO ()
supdateAuth db ar =
  withTransaction db do
    execute_ db "delete from authinfo"
    execute db "insert into authinfo(ts, access_token, refresh_token, expires_in) values(current_timestamp, ?, ?, ?)" ar

sloadAuth :: Connection -> IO AuthResponse
sloadAuth db = head <$> query_ db "select access_token, expires_in, refresh_token from authinfo"
