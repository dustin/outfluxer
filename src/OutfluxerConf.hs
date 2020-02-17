{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

module OutfluxerConf (
  OutfluxerConf(..),
  Source(..),
  Query(..),
  Target(..),
  Destination(..),
  DestFragment(..),
  parseConfFile
  ) where

import qualified Data.Text as T

import           Dhall

newtype OutfluxerConf = OutfluxerConf { sources :: [Source]} deriving(Generic, Show)

instance FromDhall OutfluxerConf

data Source = Source { host :: Text, db :: Text, queries :: [Query] } deriving(Generic, Show)

instance FromDhall Source

data Query = Query { queryText :: Text, targets :: [Target] } deriving(Generic, Show)

instance FromDhall Query

data Target = Target { field :: Text, destination :: Destination } deriving(Generic, Show)

instance FromDhall Target

newtype Destination = Destination [DestFragment] deriving(Show)

instance FromDhall Destination where
  autoWith _ = Destination . bits <$> strictText
    where bits t = f <$> T.splitOn "/" t
          f s
            | "$" `T.isPrefixOf` s = TagField (T.tail s)
            | otherwise            = ConstFragment s

data DestFragment = ConstFragment Text | TagField Text deriving(Generic, Show)

instance FromDhall DestFragment

parseConfFile :: String -> IO OutfluxerConf
parseConfFile = inputFile auto
