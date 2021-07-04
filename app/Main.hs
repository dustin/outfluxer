{-# OPTIONS_GHC -Wno-type-defaults #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Concurrent         (threadDelay)
import           Control.Lens
import           Control.Monad              (forever)
import           Control.Monad.IO.Class     (MonadIO (..))
import           Control.Monad.Logger       (LoggingT, MonadLogger, logErrorN, logInfoN, runStderrLoggingT)
import           Control.Monad.Reader       (ReaderT (..), asks, runReaderT)
import           Data.Aeson                 (Value (..))
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.HashMap.Strict        (HashMap)
import qualified Data.HashMap.Strict        as HM
import           Data.Semigroup             (sconcat)
import           UnliftIO.Async             (mapConcurrently_)

import           Data.Maybe                 (fromJust)
import           Data.Scientific            (FPFormat (..), floatingOrInteger, formatScientific)
import           Data.String                (IsString, fromString)
import           Data.Text                  (Text, pack, replace, unpack)
import           Data.Time                  (UTCTime, getCurrentTime)
import           Data.Time.Format           (defaultTimeLocale, formatTime)
import           Data.Time.LocalTime        (LocalTime (..), getCurrentTimeZone, localTimeToUTC, midnight,
                                             utcToLocalTime)
import qualified Data.Vector                as V
import qualified Database.InfluxDB          as IDB
import           Network.MQTT.Client        (MQTTClient, MQTTConfig (..), Property (..), ProtocolLevel (..), QoS (..),
                                             connectURI, mqttConfig, publishq, svrProps)
import           Network.MQTT.Topic         (Topic, mkTopic)
import           Network.URI                (URI, parseURI)
import           Options.Applicative        (Parser, auto, execParser, fullDesc, help, helper, info, long, maybeReader,
                                             option, progDesc, showDefault, strOption, value, (<**>))

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
type Outfluxer = ReaderT Env (LoggingT IO)

options :: Parser Options
options = Options
  <$> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> strOption (long "conf" <> showDefault <> value "outfluxer.conf" <> help "config file")
  <*> option auto (long "period" <> showDefault <> value 300 <> help "seconds between polls")

-- Time, Tags, Vals
data ARow = ARow UTCTime (HashMap Text Text) (HashMap Text String) deriving(Show)

instance IDB.QueryResults ARow where
  parseMeasurement prec _name tags columns fields = do
    ts <- IDB.getField "time" columns fields >>= IDB.parseUTCTime prec
    let fl = V.filter (/= "time") columns
    vals <- traverse (\c -> IDB.getField c columns fields) fl
    let nums = foldMap ms (V.zip fl vals)
    pure $ ARow ts tags nums

      where ms (k, Number x)   = HM.singleton k (ss x)
            ms (k, String s)   = HM.singleton k (unpack s)
            ms (k, Bool True)  = HM.singleton k "true"
            ms (k, Bool False) = HM.singleton k "false"
            ms _               = mempty

            ss v = formatScientific Fixed (Just $ either (const 2) (const 0) (floatingOrInteger v)) v


logErr :: MonadLogger m => Text -> m ()
logErr = logErrorN

logInfo :: MonadLogger m => Text -> m ()
logInfo = logInfoN

tshow :: Show a => a -> Text
tshow = pack . show

sleep :: MonadIO m => Int -> m ()
sleep = liftIO . threadDelay  . seconds

seconds :: Int -> Int
seconds = (* 1000000)

resolveDest :: HashMap Text Text -> Destination -> Maybe Topic
resolveDest m (Destination segs) = sconcat <$> traverse res segs
  where res (ConstFragment x) = mkTopic x
        res (TagField x)      = mkTopic =<< HM.lookup x m

conv :: IsString a => Text -> a
conv = fromString . unpack

query :: IDB.QueryParams -> Text -> IO [ARow]
query qp qt = V.toList <$> IDB.query qp (conv qt)

subs :: MonadIO m => Text -> m Text
subs qt = today >>= \t -> pure $ replace "@TODAY@" t qt

    where
      today :: MonadIO m => m Text
      today = liftIO $ pack . formatTime defaultTimeLocale "'%FT%TZ'" <$> td
        where
          td = do
            tz <- getCurrentTimeZone
            ld <- localDay . utcToLocalTime tz <$> getCurrentTime
            pure $ localTimeToUTC tz (LocalTime ld midnight)

runSrc :: Source -> Outfluxer ()
runSrc (Source host db qs) = do
  let qp = IDB.queryParams (conv db) & IDB.server . IDB.host .~ conv host
  polli <- asks (optPollInterval . opts)

  forever $ mapM_ (go qp) qs >> sleep polli

  where
    go qp (Query qt ts) = subs qt >>= \qt' -> liftIO (query qp qt') >>= mapM_ (\r -> mapM_ (msink r) ts)

        where
          msink r@(ARow rts tags fields) (Target fn d) =
            sink $ (,) <$> resolveDest tags d <*> HM.lookup fn fields

            where
              sink :: Maybe (Topic, String) -> Outfluxer ()
              sink Nothing = logErr $ mconcat ["Could not resolve destination ", tshow d,
                                               " from query ", tshow qt, ": ", tshow r]
              sink (Just (t, v)) = do
                mc <- asks mqc
                polli <- asks (optPollInterval . opts)
                liftIO $ publishq mc t (BC.pack v) True QoS2 [
                  PropMessageExpiryInterval (fromIntegral $ polli * 3),
                  PropUserProperty "ts" (BC.pack . show $ rts)]

run :: Options -> IO ()
run opts@Options{..} = do
  (OutfluxerConf srcs) <- parseConfFile optConfFile

  mc <- connectURI mqttConfig{_protocol=Protocol50} optMQTTURI
  sprops <- svrProps mc
  runStderrLoggingT $ do
    logInfo $ tshow sprops
    let env = Env mc opts

    mapConcurrently_ (\s -> runReaderT (runSrc s) env) srcs

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "InfluxDB -> mqtt gateway")
