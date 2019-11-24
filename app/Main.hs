{-# OPTIONS_GHC -Wno-type-defaults #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Concurrent         (threadDelay)
import           Control.Concurrent.Async   (mapConcurrently_)
import           Control.Lens
import           Control.Monad              (forever)
import           Control.Monad.IO.Class     (MonadIO (..))
import           Control.Monad.Reader       (ReaderT (..), asks, runReaderT)
import           Data.Aeson                 (Value (..))
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.HashMap.Strict        (HashMap)
import qualified Data.HashMap.Strict        as HM

import           Data.Maybe                 (fromJust, mapMaybe)
import           Data.Scientific            (FPFormat (..), Scientific,
                                             floatingOrInteger,
                                             formatScientific)
import           Data.String                (IsString, fromString)
import           Data.Text                  (Text, intercalate, unpack)
import           Data.Time                  (UTCTime)
import qualified Data.Vector                as V
import qualified Database.InfluxDB          as IDB
import           Network.MQTT.Client        (MQTTClient, MQTTConfig (..),
                                             Property (..), ProtocolLevel (..),
                                             QoS (..), Topic, connectURI,
                                             mqttConfig, publishq, svrProps)
import           Network.URI                (URI, parseURI)
import           Options.Applicative        (Parser, auto, execParser, fullDesc,
                                             help, helper, info, long,
                                             maybeReader, option, progDesc,
                                             showDefault, strOption, value,
                                             (<**>))
import           System.Log.Logger          (Priority (INFO), errorM, infoM,
                                             rootLoggerName, setLevel,
                                             updateGlobalLogger)

import           OutfluxerConf

data Options = Options {
  optMQTTURI        :: URI
  , optConfFile     :: String
  , optPollInterval :: Int
  }

data Env = Env {
  mqc    :: MQTTClient
  , opts :: Options
  }
type Outfluxer = ReaderT Env IO

options :: Parser Options
options = Options
  <$> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> strOption (long "conf" <> showDefault <> value "outfluxer.conf" <> help "config file")
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

logErr :: MonadIO m => String -> m ()
logErr = liftIO . errorM rootLoggerName

logInfo :: MonadIO m => String -> m ()
logInfo = liftIO . infoM rootLoggerName

sleep :: MonadIO m => Int -> m ()
sleep = liftIO . threadDelay  . seconds

seconds :: Int -> Int
seconds = (* 1000000)

resolveDest :: HashMap Text Text -> Destination -> Maybe Text
resolveDest m (Destination segs) = intercalate "/" <$> traverse res segs
  where res (ConstFragment x) = Just x
        res (TagField x)      = HM.lookup x m

conv :: IsString a => Text -> a
conv = fromString . unpack

query :: IDB.QueryParams -> Text -> IO [NumRow]
query qp qt = V.toList <$> IDB.query qp (conv qt)

runSrc :: Source -> Outfluxer ()
runSrc (Source host db qs) = do
  let qp = IDB.queryParams (conv db) & IDB.server . IDB.host .~ conv host
  polli <- asks (optPollInterval . opts)

  forever $ mapM_ (go qp) qs >> sleep polli

  where
    go qp (Query qt ts) = liftIO (query qp qt) >>= mapM_ (\r -> mapM_ (msink r) ts)

        where
          msink r@(NumRow rts tags fields) (Target fn d) =
            sink $ (,) <$> resolveDest tags d <*> HM.lookup fn fields

            where
              sink :: Maybe (Topic, Scientific) -> Outfluxer ()
              sink Nothing = logErr $ mconcat ["Could not resolve destination ", show d,
                                               " from query ", show qt, ": ", show r]
              sink (Just (t, v)) = do
                mc <- asks mqc
                polli <- asks (optPollInterval . opts)
                liftIO $ publishq mc t (BC.pack $ ss v) True QoS2 [
                  PropMessageExpiryInterval (fromIntegral $ polli * 3),
                  PropUserProperty "ts" (BC.pack . show $ rts)]

              ss v = formatScientific Fixed (Just $ either (const 2) (const 0) (floatingOrInteger v)) v

run :: Options -> IO ()
run opts@Options{..} = do
  updateGlobalLogger rootLoggerName (setLevel INFO)

  (OutfluxerConf srcs) <- parseConfFile optConfFile

  mc <- connectURI mqttConfig{_protocol=Protocol50} optMQTTURI
  logInfo =<< (show <$> svrProps mc)
  let env = Env mc opts

  mapConcurrently_ (\s -> runReaderT (runSrc s) env) srcs

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "InfluxDB -> mqtt gateway")
