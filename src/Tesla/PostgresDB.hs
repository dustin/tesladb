{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE RankNTypes        #-}

module Tesla.PostgresDB (insertVData, dbInit, listDays, listDay, fetchDatum, withDB) where

import           Control.Monad                    (guard, void)
import           Control.Monad.Catch              (MonadMask, bracket)
import           Control.Monad.IO.Class           (MonadIO (..))
import           Data.ByteString                  (ByteString)
import           Data.Time.Clock                  (UTCTime)
import           Database.PostgreSQL.Simple
import           Database.PostgreSQL.Simple.SqlQQ (sql)

import           Tesla.Car                        (VehicleData, teslaTS)

dbInit :: Connection -> IO ()
dbInit db = void $ execute_ db [sql|
                                   create table data (
                                     ts timestamp not null primary key,
                                     vts timestamp generated always as (to_timestamp(cast (data->'vehicle_state'->>'timestamp' as real) / 1000.0) at time zone 'US/Pacific') stored,
                                     data json
                                   )
                                   |]

insertVData :: Connection -> VehicleData -> IO ()
insertVData db vdata = void $ execute db "insert into data(ts, data) values(?, ?)" (teslaTS vdata, vdata)

listDays :: Connection -> IO [(String,Int)]
listDays db = query_ db "select date(ts)::text as day, count(*) from data group by day"

listDay :: Connection -> String -> IO [UTCTime]
listDay db d = fmap fromOnly <$> query db "select ts at time zone 'utc' from data where date(ts) = ?" (Only d)

fetchDatum :: Connection -> UTCTime -> IO VehicleData
fetchDatum db t = do
  rows <- query db "select data from data where ts = ?" (Only t)
  guard $ length rows == 1
  pure . fromOnly . head $ rows

-- | withDB runs the given action with an initialized shorten DB.
withDB :: forall m a. (MonadMask m, MonadIO m) => ByteString -> (Connection -> m a) -> m a
withDB path = bracket (liftIO $ connectPostgreSQL path) (liftIO . close)
