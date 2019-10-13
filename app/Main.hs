{-# OPTIONS_GHC -Wno-type-defaults #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.Async   (mapConcurrently_)
import           Control.Lens
import           Control.Monad              (forever)
import           Data.Aeson                 (Value (..))
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.HashMap.Strict        (HashMap)
import qualified Data.HashMap.Strict        as HM
import           Data.Maybe                 (fromJust, isNothing, mapMaybe)
import           Data.Scientific            (Scientific, floatingOrInteger)
import           Data.String                (IsString, fromString)
import           Data.Text                  (Text, intercalate, unpack)
import           Data.Time                  (UTCTime)
import qualified Data.Vector                as V
import qualified Database.InfluxDB          as IDB
import           Network.MQTT.Client        (MQTTClient, MQTTConfig (..),
                                             Property (..), ProtocolLevel (..),
                                             QoS (..), connectURI, mqttConfig,
                                             publishq, svrProps)
import           Network.URI                (URI, parseURI)
import           Options.Applicative        (Parser, auto, execParser, fullDesc,
                                             help, helper, info, long,
                                             maybeReader, option, progDesc,
                                             short, showDefault, strOption,
                                             switch, value, (<**>))
import           System.Log.Logger          (Priority (DEBUG, INFO), debugM,
                                             errorM, infoM, rootLoggerName,
                                             setLevel, updateGlobalLogger)

import           OutfluxerConf

data Options = Options {
  optMQTTURI        :: URI
  , optConfFile     :: String
  , optVerbose      :: Bool
  , optPollInterval :: Int
  }

options :: Parser Options
options = Options
  <$> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> strOption (long "conf" <> showDefault <> value "outfluxer.conf" <> help "config file")
  <*> switch (long "verbose" <> short 'v' <> help "Log more stuff")
  <*> option auto (long "period" <> showDefault <> value 300 <> help "seconds between polls")

-- Time, Tags, Vals
data NumRow = NumRow UTCTime (HashMap Text Text) (HashMap Text Scientific) deriving(Show)

instance IDB.QueryResults NumRow where
  parseResults prec = IDB.parseResultsWithDecoder IDB.strictDecoder $ \_ m columns fields -> do
    ts <- IDB.getField "time" columns fields >>= IDB.parseUTCTime prec
    let fl = filter (/= "time") $ V.toList columns
    vals <- mapM (\c -> IDB.getField c columns fields) fl
    let nums = mapMaybe ms (zip fl vals)
    pure $ NumRow ts m (HM.fromList nums)

      where ms (k,Number x) = Just (k,x)
            ms _            = Nothing

logErr :: String -> IO ()
logErr = errorM rootLoggerName

logInfo :: String -> IO ()
logInfo = infoM rootLoggerName

logDebug :: String -> IO ()
logDebug = debugM rootLoggerName

seconds :: Int -> Int
seconds = (* 1000000)

delaySeconds :: Int -> IO ()
delaySeconds = threadDelay . seconds

resolveDest :: HashMap Text Text -> Destination -> Maybe Text
resolveDest m (Destination segs) = intercalate "/" <$> sequence (res <$> segs)
  where res (ConstFragment x) = Just x
        res (TagField x)      = HM.lookup x m

conv :: IsString a => Text -> a
conv = fromString . unpack

query :: IDB.QueryParams -> Text -> IO [NumRow]
query qp qt = do
  let q = conv qt
  rs <- IDB.query qp q :: IO (V.Vector NumRow)
  pure $ V.toList rs

runSrc :: Options -> MQTTClient -> Source -> IO ()
runSrc Options{..} mc (Source host db qs) = do
  let qp = IDB.queryParams (conv db) & IDB.server . IDB.host .~ conv host

  forever $ mapM_ (go qp) qs >> delaySeconds optPollInterval

  where
    go qp (Query qt ts) = do
      rs <- query qp qt
      mapM_ (\r -> mapM_ (msink r) ts) rs

        where
          msink :: NumRow -> Target -> IO ()
          msink r@(NumRow _ tags fields) (Target fn d) = do
            let mrd = resolveDest tags d
                mrf = HM.lookup fn fields
            if isNothing mrd || isNothing mrf
              then logErr $ mconcat ["Could not resolve destination ", show d,
                                     " from query ", show qt, ": ", show r]
              else sink (fromJust mrd) (fromJust mrf)

              where
                sink t v = do
                  logDebug $ mconcat ["Sinking ", show fn, " to ", show t, " from ", show r]
                  publishq mc t (BC.pack $ ss v) True QoS2 [PropMessageExpiryInterval (fromIntegral $ optPollInterval * 3)]

                ss v = either show show (floatingOrInteger v)

run :: Options -> IO ()
run opts@Options{..} = do
  updateGlobalLogger rootLoggerName (setLevel $ if optVerbose then DEBUG else INFO)

  (OutfluxerConf srcs) <- parseConfFile optConfFile

  mc <- connectURI mqttConfig{_protocol=Protocol50, _connProps=[]} optMQTTURI
  logInfo =<< (show <$> svrProps mc)

  mapConcurrently_ (runSrc opts mc) srcs

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "InfluxDB -> mqtt gateway")
