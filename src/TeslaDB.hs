{-# LANGUAGE OverloadedStrings #-}

module TeslaDB (insertVData) where

import           Database.SQLite.Simple hiding (bind, close)

import           Tesla                  (VehicleData, teslaTS)

insertStatement :: Query
insertStatement = "insert into data(ts, data) values(?, ?)"

insertVData :: Connection -> VehicleData -> IO ()
insertVData db vdata = execute db insertStatement (teslaTS vdata, vdata)
