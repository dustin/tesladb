module Main where

import qualified Data.ByteString.Lazy             as BL
import qualified Data.Text.Encoding               as TE
import           Data.Time.Clock                  (UTCTime)
import           Database.SQLite.Simple           hiding (bind, close)
import           Database.SQLite.Simple.FromField
import           Database.SQLite.Simple.Ok
import           System.Environment               (getArgs)

import           Tesla.Car
import           Tesla.SqliteDB

newtype VD = VD { unVD :: VehicleData }

instance FromField VD where
  fromField f = case fieldData f of
                  (SQLBlob b) -> Ok . VD . BL.fromStrict $ b
                  (SQLText t) -> Ok . VD . BL.fromStrict . TE.encodeUtf8 $ t
                  _           -> returnError ConversionFailed f "need some text or blobs or whatever"

update :: String -> String -> IO ()
update old new = withConnection old srcData

    where srcData src = withConnection new sinkData
            where sinkData sink = do
                    dbInit sink
                    execute_ sink "create table if not exists rejects (ts timestamp, data blob)"
                    withTransaction sink $
                      fold_ src "select ts, data from data" () (const ins)

                    where
                      ins :: (UTCTime, VD) -> IO ()
                      ins (t, VD vd) =
                        case maybeTeslaTS vd of
                          Nothing -> execute sink "insert into rejects values (?,?)" (t,vd)
                          Just _  -> insertVData sink vd

main :: IO ()
main = do
  [old,new] <- getArgs
  update old new
