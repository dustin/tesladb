{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE QuasiQuotes #-}

module Tesla.DB.Postgres (runStr, runConn) where

import           Cleff
import           Control.Exception          (throwIO)
import qualified Data.Aeson                 as J
import           Data.ByteString.Char8      (pack)
import qualified Data.ByteString.Lazy       as BL
import           Data.Foldable              (toList)
import qualified Data.Text                  as T
import           Data.Time.Clock            (UTCTime)
import           Hasql.Connection           (Connection, acquire)
import           Hasql.Session              (Session, run)
import qualified Hasql.Session              as Session
import           Hasql.TH
import qualified Hasql.Transaction          as TX
import           Hasql.Transaction.Sessions (transaction)
import qualified Hasql.Transaction.Sessions as TX

import           Tesla.Auth                 (AuthResponse (..))
import           Tesla.Car                  (VehicleData, teslaTS)
import           Tesla.DB

runStr :: IOE :> es => String -> Eff (DB : es) a -> Eff es a
runStr s f = liftIO (acquire (pack s)) >>= either (error . show) (flip runConn f)

runConn :: forall es a. (IOE :> es) => Connection -> Eff (DB : es) a -> Eff es a
runConn db = interpret \case
  InitDB            -> rundb pdbInit
  InsertVData vdata -> rundb $ pinsertVData vdata
  ListDays          -> rundb plistDays
  ListDay d         -> rundb $ plistDay d
  FetchDatum t      -> rundb $ pfetchDatum t
  UpdateAuth ar     -> rundb $ pupdateAuth ar
  LoadAuth          -> rundb ploadAuth

  where
    rundb :: Session b -> Eff es b
    rundb f = liftIO $ either throwIO pure =<< run f db

pdbInit :: Session ()
pdbInit = do
  Session.sql "create table if not exists data (ts timestamp not null primary key, vts timestamptz generated always as (to_timestamp(cast (data->'vehicle_state'->>'timestamp' as real) / 1000.0) at time zone 'US/Pacific') stored, data jsonb not null);"
  Session.sql "create table if not exists authinfo (ts timestamp, access_token varchar, refresh_token varchar, expires_in int);"

pinsertVData :: VehicleData -> Session ()
pinsertVData vdata = Session.statement (teslaTS vdata, J.decode vdata) st
  where
    st = [resultlessStatement|insert into data (ts, data) values ($1 :: timestamptz, $2 :: jsonb?)|]

plistDays :: Session [(String,Int)]
plistDays = fmap dec . toList <$> Session.statement () st
  where
    dec (a, b) = (T.unpack a, fromIntegral b)
    st = [vectorStatement|select date(ts) :: text as day, count(*) :: int8 from data group by day|]

plistDay :: String -> Session [UTCTime]
plistDay d = toList <$> Session.statement (T.pack d) st
  where
    st = [vectorStatement|select (ts at time zone 'utc') :: timestamptz from data where date(ts)::text = $1 :: text|]

pfetchDatum :: UTCTime -> Session VehicleData
pfetchDatum t = BL.fromStrict <$> Session.statement t st
  where
    st = [singletonStatement|select data :: bytea from data where ts = $1 :: timestamptz|]

pupdateAuth :: AuthResponse -> Session ()
pupdateAuth ar = transaction TX.Serializable TX.Write do
  TX.statement () del
  TX.statement (T.pack (_access_token ar), T.pack (_refresh_token ar), fromIntegral (_expires_in ar)) ins

  where
    del = [resultlessStatement|delete from authinfo|]
    ins = [resultlessStatement|insert into authinfo (ts, access_token, refresh_token, expires_in) values(current_timestamp, $1 :: text, $2 :: text, $3 :: int8)|]

ploadAuth :: Session AuthResponse
ploadAuth = dec <$> Session.statement () st
  where
    dec (a, b, c) = AuthResponse (T.unpack a) (fromIntegral b) (T.unpack c)
    st = [singletonStatement|select access_token :: text, expires_in :: int8, refresh_token :: text from authinfo|]
