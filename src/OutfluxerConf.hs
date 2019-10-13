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

import           Control.Applicative        ((<|>))
import           Data.Text                  (Text, pack)
import           Data.Void                  (Void)
import           Text.Megaparsec            (Parsec, between, manyTill, noneOf,
                                             option, parse, sepBy, some, try)
import           Text.Megaparsec.Char       (char, space1)
import qualified Text.Megaparsec.Char.Lexer as L
import           Text.Megaparsec.Error      (errorBundlePretty)

type Parser = Parsec Void Text

newtype OutfluxerConf =  OutfluxerConf [Source] deriving(Show)

data Source = Source Text Text [Query] deriving(Show)

data Query = Query Text [Target] deriving(Show)

data Target = Target Text Destination deriving(Show)

newtype Destination = Destination [DestFragment] deriving(Show)

data DestFragment = ConstFragment Text | TagField Text deriving(Show)

sc :: Parser ()
sc = L.space space1 lineComment blockComment
  where
    lineComment  = L.skipLineComment "//"
    blockComment = L.skipBlockComment "/*" "*/"

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

symbol :: Text -> Parser Text
symbol = L.symbol sc

qstr :: Parser Text
qstr = pack <$> (char '"' >> manyTill L.charLiteral (char '"'))

astr :: Parser Text
astr = pack <$> some (noneOf ['\n', ' '])

parseSrc :: Parser Source
parseSrc = do
  server <- sc <* (symbol "from") *> lexeme astr
  dbname <- lexeme astr
  ws <- between (symbol "{") (symbol "}") (some $ try parseQuery)
  pure $ Source server dbname ws

parseQuery :: Parser Query
parseQuery = do
  qs <- symbol "query" *> lexeme qstr
  ts <- between (symbol "{") (symbol "}") (some $ try parseTarget)
  pure $ Query qs ts

parseTarget :: Parser Target
parseTarget = do
  f <- lexeme astr <* lexeme "->"
  d <- lexeme (parseDestFragment `sepBy` "/")
  pure $ Target f (Destination d)

parseDestFragment :: Parser DestFragment
parseDestFragment = tf <|> cf
  where
    tf = TagField <$> ("$" *> s)
    cf = ConstFragment <$> s
    s = pack <$> some (noneOf ['\n', ' ', '/'])

parseOutfluxerConf :: Parser OutfluxerConf
parseOutfluxerConf = OutfluxerConf <$> some parseSrc

parseFile :: Parser a -> String -> IO a
parseFile f s = pack <$> readFile s >>= either (fail.errorBundlePretty) pure . parse f s

parseConfFile :: String -> IO OutfluxerConf
parseConfFile = parseFile parseOutfluxerConf
