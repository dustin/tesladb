module Tesla.RunDB (withDB) where

import           Cleff
import           Data.List         (isPrefixOf)
import           Tesla.DB
import qualified Tesla.DB.Postgres as Postgres
import qualified Tesla.DB.SQLite   as SQLite

withDB :: IOE :> es => String -> Eff (DB : es) a -> Eff es a
withDB s
  | "postgres:" `isPrefixOf` s = Postgres.runStr s
  | otherwise = SQLite.runStr s

