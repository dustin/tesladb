{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE QuasiQuotes #-}

module Tesla.DB.Postgres (runStr, runConn) where

import           Cleff
import           Control.Monad                      (guard, void)
import           Data.String
import           Data.Time.Clock                    (UTCTime)
import           Database.PostgreSQL.Simple
import           Database.PostgreSQL.Simple.FromRow
import           Database.PostgreSQL.Simple.SqlQQ   (sql)
import           Database.PostgreSQL.Simple.ToRow

import           Tesla.Auth                         (AuthResponse (..))
import           Tesla.Car                          (VehicleData, teslaTS)
import           Tesla.DB

runStr :: IOE :> es => String -> Eff (DB : es) a -> Eff es a
runStr s f = liftIO (connectPostgreSQL (fromString s)) >>= flip runConn f

runConn :: (IOE :> es) => Connection -> Eff (DB : es) a -> Eff es a
runConn db = interpret \case
  InitDB            -> liftIO $ pdbInit db
  InsertVData vdata -> liftIO $ pinsertVData db vdata
  ListDays          -> liftIO $ plistDays db
  ListDay d         -> liftIO $ plistDay db d
  FetchDatum t      -> liftIO $ pfetchDatum db t
  UpdateAuth ar     -> liftIO $ pupdateAuth db ar
  LoadAuth          -> liftIO $ ploadAuth db

pdbInit :: Connection -> IO ()
pdbInit db = void $ execute_ db [sql|
                                   create table if not exists data (
                                     ts timestamp not null primary key,
                                     vts timestamptz generated always as (to_timestamp(cast (data->'vehicle_state'->>'timestamp' as real) / 1000.0) at time zone 'US/Pacific') stored,
                                     data jsonb not null
                                   );
                                   create table if not exists authinfo (ts timestamp, access_token varchar, refresh_token varchar, expires_in int);
                                   |]

pinsertVData :: Connection -> VehicleData -> IO ()
pinsertVData db vdata = void $ execute db "insert into data(ts, data) values(?, ?)" (teslaTS vdata, vdata)

plistDays :: Connection -> IO [(String,Int)]
plistDays db = query_ db "select date(ts)::text as day, count(*) from data group by day"

plistDay :: Connection -> String -> IO [UTCTime]
plistDay db d = fmap fromOnly <$> query db "select ts at time zone 'utc' from data where date(ts) = ?" (Only d)

pfetchDatum :: Connection -> UTCTime -> IO VehicleData
pfetchDatum db t = do
  rows <- query db "select data from data where ts = ?" (Only t)
  guard $ length rows == 1
  pure . fromOnly . head $ rows

instance ToRow AuthResponse where
  toRow (AuthResponse tok expiry refresh) = toRow (tok, refresh, expiry)

instance FromRow AuthResponse where
  fromRow = AuthResponse <$> field <*> field <*> field

pupdateAuth :: Connection -> AuthResponse -> IO ()
pupdateAuth db ar =
  withTransaction db do
    void $ execute_ db "delete from authinfo"
    void $ execute db "insert into authinfo(ts, access_token, refresh_token, expires_in) values(current_timestamp, ?, ?, ?)" ar

ploadAuth :: Connection -> IO AuthResponse
ploadAuth db = head <$> query_ db "select access_token, expires_in, refresh_token from authinfo"
