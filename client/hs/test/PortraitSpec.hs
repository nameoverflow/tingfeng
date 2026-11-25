{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (forM_, unless)
import qualified Data.Set as S
import qualified Data.Text as T
import System.Directory (doesFileExist)
import Tingfeng.State (portraitScoreFile)

assert :: String -> Bool -> IO ()
assert message ok = unless ok (fail message)

main :: IO ()
main = do
  let names = ["A", "B", "C", "D"]
      scores = [0, 2, 4, 6, 8, 10]
      genders = ["female", "male"]
  assert "odd scores round up" (portraitScoreFile "female" 1 "A" == portraitScoreFile "female" 2 "A")
  assert "score clamps at zero" (portraitScoreFile "male" (-2) "B" == portraitScoreFile "male" 0 "B")
  assert "score clamps at ten" (portraitScoreFile "male" 12 "B" == portraitScoreFile "male" 10 "B")
  assert "high scores use the updated portrait set" ("beauty-v9-" `T.isPrefixOf` portraitScoreFile "female" 8 "A")
  assert "middle scores keep the existing portrait set" ("beauty-v8-" `T.isPrefixOf` portraitScoreFile "female" 6 "A")
  assert "trimmed names select the same portrait" (portraitScoreFile "female" 6 " 阿青 " == portraitScoreFile "female" 6 "阿青")
  assert "unknown gender uses the former male-looking low-score fallback" (portraitScoreFile "unknown" 2 "A" == portraitScoreFile "male" 2 "A")
  assert "unknown gender uses the former female-looking high-score fallback" (portraitScoreFile "unknown" 7 "A" == portraitScoreFile "female" 8 "A")
  forM_ genders $ \gender -> forM_ scores $ \score -> do
    let ids = S.fromList [portraitScoreFile gender score name | name <- names]
    assert "four names cover all four variants" (S.size ids == 4)
    forM_ ids $ \portrait -> do
      let file = "../public/portraits/" <> T.unpack portrait <> ".png"
      exists <- doesFileExist file
      assert ("missing portrait: " <> file) exists
  putStrLn "Portrait selection: stable name mapping, score boundaries, fallback and 48 assets passed"
