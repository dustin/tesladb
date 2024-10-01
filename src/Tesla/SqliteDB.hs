module Tesla.SqliteDB (insertVData, dbInit, listDays, listDay, fetchDatum) where

import           Control.Monad          (guard)
import           Data.Time.Clock        (UTCTime)
import           Database.SQLite.Simple hiding (bind, close)

import           Tesla.Car              (VehicleData, teslaTS)

dbInit :: Connection -> IO ()
dbInit db = do
  execute_ db "pragma auto_vacuum = incremental"
  execute_ db "create table if not exists data (ts timestamp, data blob)"
  execute_ db "create unique index if not exists data_ts on data(ts)"

insertVData :: Connection -> VehicleData -> IO ()
insertVData db vdata = execute db "insert into data(ts, data) values(?, ?)" (teslaTS vdata, vdata)

listDays :: Connection -> IO [(String,Int)]
listDays db = query_ db "select date(ts) as day, count(*) from data group by day"

listDay :: Connection -> String -> IO [UTCTime]
listDay db d = fmap fromOnly <$> query db "select ts from data where date(ts) = ?" (Only d)

fetchDatum :: Connection -> UTCTime -> IO VehicleData
fetchDatum db t = do
  rows <- query db "select data from data where ts = ?" (Only t)
  guard $ length rows == 1
  pure . fromOnly . head $ rows
