{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

import Control.Monad
import Control.Lens
import Data.Aeson ((.:))
import DeckGo.Handler
import Data.Time.Clock (getCurrentTime)
import System.Environment (getEnv)
import UnliftIO
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Internal as Aeson
import qualified Data.Aeson.Parser as Aeson
import qualified Data.Aeson.Parser.Internal as Aeson
import qualified Data.Aeson.Types as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Hasql.Connection as Hasql
import qualified Network.AWS as Aws
import qualified Network.AWS.CloudFront as CloudFront
import qualified Network.Wai.Handler.Lambda as Lambda

main :: IO ()
main = do
    hSetBuffering stdin LineBuffering
    hSetBuffering stdout LineBuffering

    liftIO $ putStrLn "Booting..."
    env <- Aws.newEnv Aws.Discover

    liftIO $ putStrLn "Booted!"

    putStrLn "entering loop..."
    forever $ do
      line <- BS8.getLine
      putStrLn $ "Got line!: " <> show line
      case decodeInput parseSQSRequest line of
        Right (fp, presPrefixes) -> do
          putStrLn $ "Got input!"
          putStrLn $
            "presentation prefixes: " <> concatMap T.unpack presPrefixes
          when (length presPrefixes /= 1) $
            putStrLn $
              "Warning: got " <> show (length presPrefixes) <> "deck IDs"
          -- conn <- getPostgresqlConnection
          forM_ presPrefixes (dirtyPres env)
          Lambda.writeFileAtomic fp (BL.toStrict $ Aeson.encode ())
        Left e -> error $ show e

dirtyPres :: Aws.Env -> T.Text -> IO ()
dirtyPres env presPrefix = do
    res <- timeout (5*1000*1000) dirty
    print res
  where
    dirty = do
      now <- getCurrentTime
      runAWS env $ Aws.send $ CloudFront.createInvalidation
        "E2D979P0TT1UFC" $ -- TODO: env var
        CloudFront.invalidationBatch
          (CloudFront.paths 1 & CloudFront.pItems .~ [ "/" <> presPrefix <> "*" ])
          (tshow now)

decodeInput
  :: (Aeson.Value -> Aeson.Parser a)
  -> BS.ByteString
  -> Either (Aeson.JSONPath, String) (FilePath, a)
decodeInput parseEvent =
    Aeson.eitherDecodeStrictWith Aeson.jsonEOF $ Aeson.iparse $
      Aeson.withObject "input" $ \obj ->
        (,) <$>
          obj .: "responseFile" <*>
          (obj .: "request" >>= parseEvent)

parseSQSRequest :: Aeson.Value -> Aeson.Parser [T.Text]
parseSQSRequest = Aeson.withObject "request" $ \o -> do
    records <- o .: "Records"
    forM records $ Aeson.withObject "record" $ \o' -> do
      jsonEncodedBody <- o' .: "body"
      case  Aeson.decodeStrict (T.encodeUtf8 jsonEncodedBody) of
        Nothing -> mzero
        Just path -> pure path

getPostgresqlConnection :: IO Hasql.Connection
getPostgresqlConnection = do
    user <- getEnv "PGUSER"
    password <- getEnv "PGPASSWORD"
    host <- getEnv "PGHOST"
    db <- getEnv "PGDATABASE"
    port <- getEnv "PGPORT"
    Hasql.acquire (
      Hasql.settings
        (BS8.pack host)
        (read port)
        (BS8.pack user)
        (BS8.pack password)
        (BS8.pack db)
      ) >>= \case
        Left e -> error (show e)
        Right c -> pure c
