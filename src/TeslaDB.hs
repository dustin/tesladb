{-# LANGUAGE OverloadedStrings #-}

module TeslaDB (insertVData, dbInit) where

import           Database.SQLite.Simple hiding (bind, close)

import           Tesla                  (VehicleData, teslaTS)

createStatement :: Query
createStatement = "create table if not exists data (ts timestamp, data blob)"

createIndexStatement :: Query
createIndexStatement = "create unique index if not exists data_ts on data(ts)"

dbInit :: Connection -> IO ()
dbInit db = do
  execute_ db "pragma auto_vacuum = incremental"
  execute_ db createStatement
  execute_ db createIndexStatement

insertStatement :: Query
insertStatement = "insert into data(ts, data) values(?, ?)"

insertVData :: Connection -> VehicleData -> IO ()
insertVData db vdata = execute db insertStatement (teslaTS vdata, vdata)

