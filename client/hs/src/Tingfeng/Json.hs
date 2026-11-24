{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Tingfeng.Json
  ( JVal (..),
    parseJson,
    encodeJson,
    jObj,
    jField,
    jFieldDef,
    jFieldMaybe,
    jText,
    jInt,
    jDouble,
    jBool,
    jList,
    jMap,
    (.=),
  )
where

import Data.Char (chr, digitToInt, isDigit, isHexDigit, isSpace, ord)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Builder as B
import qualified Data.Text.Lazy.Builder.Int as BI
import qualified Data.Text.Lazy.Builder.RealFloat as BF

data JVal
  = JNull
  | JBool !Bool
  | JNum !Double
  | JStr !Text
  | JArr ![JVal]
  | JObj !(M.Map Text JVal)
  deriving (Show, Eq)

(.=) :: Text -> JVal -> (Text, JVal)
k .= v = (k, v)

jObj :: [(Text, JVal)] -> JVal
jObj = JObj . M.fromList

encodeJson :: JVal -> Text
encodeJson = TL.toStrict . B.toLazyText . buildVal
  where
    buildVal JNull = "null"
    buildVal (JBool True) = "true"
    buildVal (JBool False) = "false"
    buildVal (JNum d)
      | isNaN d || isInfinite d = "0"
      | abs d < 2.0e6 =
          let !n = round (d * 1000.0) :: Int
              !a = abs n
              (!q, !r) = a `quotRem` 1000
              sign = if n < 0 then B.singleton '-' else mempty
           in if r == 0
                then sign <> BI.decimal q
                else
                  let pad
                        | r < 10 = "00"
                        | r < 100 = "0"
                        | otherwise = mempty
                      (!rTrim, _) =
                        if r `rem` 100 == 0
                          then (r `quot` 100, ())
                          else if r `rem` 10 == 0 then (r `quot` 10, ()) else (r, ())
                   in if r < 100
                        then sign <> BI.decimal q <> B.singleton '.' <> pad <> BI.decimal r
                        else sign <> BI.decimal q <> B.singleton '.' <> BI.decimal rTrim
      | otherwise = BF.realFloat d
    buildVal (JStr s) = buildStr s
    buildVal (JArr xs) = "[" <> commas (map buildVal xs) <> "]"
    buildVal (JObj mp) =
      "{"
        <> commas [buildStr k <> ":" <> buildVal v | (k, v) <- M.toList mp]
        <> "}"

    commas [] = mempty
    commas [x] = x
    commas (x : xs) = x <> mconcat ["," <> y | y <- xs]

    buildStr s = "\"" <> T.foldr (\c acc -> esc c <> acc) "\"" s
    esc '"' = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\r' = "\\r"
    esc '\t' = "\\t"
    esc c
      | ord c < 0x20 = "\\u" <> hex4 (ord c)
      | otherwise = B.singleton c
    hex4 n =
      let h i = "0123456789abcdef" !! ((n `div` i) `mod` 16)
       in B.fromString [h 4096, h 256, h 16, h 1]

parseJson :: Text -> Either String JVal
parseJson input =
  case pVal (skipWS input) of
    Left err -> Left err
    Right (v, rest) ->
      let rest' = skipWS rest
       in if T.null rest'
            then Right v
            else Left ("Trailing input: " <> T.unpack (T.take 32 rest'))

skipWS :: Text -> Text
skipWS = T.dropWhile isSpace

pVal :: Text -> Either String (JVal, Text)
pVal t = case T.uncons t of
  Nothing -> Left "Unexpected end of JSON"
  Just (c, rest)
    | c == '"' -> do
        (s, r) <- pString rest
        Right (JStr s, r)
    | c == '{' -> pObject (skipWS rest)
    | c == '[' -> pArray (skipWS rest)
    | c == 't' ->
        case T.stripPrefix "rue" rest of
          Just r -> Right (JBool True, r)
          Nothing -> Left "Invalid literal starting with t"
    | c == 'f' ->
        case T.stripPrefix "alse" rest of
          Just r -> Right (JBool False, r)
          Nothing -> Left "Invalid literal starting with f"
    | c == 'n' ->
        case T.stripPrefix "ull" rest of
          Just r -> Right (JNull, r)
          Nothing -> Left "Invalid literal starting with n"
    | c == '-' || isDigit c -> pNumber t
    | otherwise -> Left ("Unexpected char: " <> [c])

pString :: Text -> Either String (Text, Text)
pString = go []
  where
    go acc t = case T.uncons t of
      Nothing -> Left "Unterminated string"
      Just ('"', rest) -> Right (T.pack (reverse acc), rest)
      Just ('\\', rest) -> case T.uncons rest of
        Nothing -> Left "Unterminated escape"
        Just (e, r2) -> case e of
          '"' -> go ('"' : acc) r2
          '\\' -> go ('\\' : acc) r2
          '/' -> go ('/' : acc) r2
          'b' -> go ('\b' : acc) r2
          'f' -> go ('\f' : acc) r2
          'n' -> go ('\n' : acc) r2
          'r' -> go ('\r' : acc) r2
          't' -> go ('\t' : acc) r2
          'u' -> do
            (code1, r3) <- pHex4 r2
            if code1 >= 0xD800 && code1 <= 0xDBFF
              then case T.stripPrefix "\\u" r3 of
                Just r4 -> do
                  (code2, r5) <- pHex4 r4
                  if code2 >= 0xDC00 && code2 <= 0xDFFF
                    then
                      let cp = 0x10000 + ((code1 - 0xD800) * 0x400) + (code2 - 0xDC00)
                       in go (chr cp : acc) r5
                    else go (chr code1 : acc) r3
                Nothing -> go (chr code1 : acc) r3
              else go (chr code1 : acc) r3
          other -> go (other : acc) r2
      Just (c, rest) -> go (c : acc) rest

    pHex4 t =
      let (h, r) = T.splitAt 4 t
       in if T.length h == 4 && T.all isHexDigit h
            then
              let val = T.foldl' (\n c -> n * 16 + digitToInt c) 0 h
               in Right (val, r)
            else Left "Invalid \\uXXXX escape"

pNumber :: Text -> Either String (JVal, Text)
pNumber t =
  let (numTxt, rest) = T.span isNumChar t
   in case reads (T.unpack numTxt) :: [(Double, String)] of
        [(d, "")] -> Right (JNum d, rest)
        _ -> Left ("Invalid number: " <> T.unpack numTxt)
  where
    isNumChar c = isDigit c || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E'

pArray :: Text -> Either String (JVal, Text)
pArray t = case T.uncons t of
  Just (']', rest) -> Right (JArr [], rest)
  _ -> go [] t
  where
    go acc s = do
      (v, r1) <- pVal (skipWS s)
      let r2 = skipWS r1
      case T.uncons r2 of
        Just (',', r3) -> go (v : acc) (skipWS r3)
        Just (']', r3) -> Right (JArr (reverse (v : acc)), r3)
        _ -> Left "Expected ',' or ']' in array"

pObject :: Text -> Either String (JVal, Text)
pObject t = case T.uncons t of
  Just ('}', rest) -> Right (JObj M.empty, rest)
  _ -> go [] t
  where
    go acc s = case T.uncons (skipWS s) of
      Just ('"', r1) -> do
        (k, r2) <- pString r1
        case T.uncons (skipWS r2) of
          Just (':', r3) -> do
            (v, r4) <- pVal (skipWS r3)
            case T.uncons (skipWS r4) of
              Just (',', r5) -> go ((k, v) : acc) (skipWS r5)
              Just ('}', r5) -> Right (JObj (M.fromList (reverse ((k, v) : acc))), r5)
              _ -> Left "Expected ',' or '}' in object"
          _ -> Left "Expected ':' after object key"
      _ -> Left "Expected string key in object"

jField :: (JVal -> Maybe a) -> Text -> M.Map Text JVal -> Maybe a
jField dec k mp = M.lookup k mp >>= dec

jFieldDef :: a -> (JVal -> Maybe a) -> Text -> M.Map Text JVal -> a
jFieldDef def dec k mp = maybe def id (jField dec k mp)

jFieldMaybe :: (JVal -> Maybe a) -> Text -> M.Map Text JVal -> Maybe a
jFieldMaybe dec k mp = case M.lookup k mp of
  Nothing -> Nothing
  Just JNull -> Nothing
  Just v -> dec v

jText :: JVal -> Maybe Text
jText (JStr s) = Just s
jText _ = Nothing

jDouble :: JVal -> Maybe Double
jDouble (JNum d) = Just d
jDouble _ = Nothing

jInt :: JVal -> Maybe Int
jInt (JNum d) = Just (round d)
jInt _ = Nothing

jBool :: JVal -> Maybe Bool
jBool (JBool b) = Just b
jBool _ = Nothing

jList :: (JVal -> Maybe a) -> JVal -> Maybe [a]
jList dec (JArr xs) = traverse dec xs
jList _ _ = Nothing

jMap :: JVal -> Maybe (M.Map Text JVal)
jMap (JObj m) = Just m
jMap _ = Nothing
