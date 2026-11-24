{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (forM_, unless)
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (getCurrentDirectory)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import Tingfeng.Battle
import Tingfeng.Catalog
import Tingfeng.Pose
import Tingfeng.Protocol

assertBool :: String -> Bool -> IO ()
assertBool msg ok = unless ok $ do
  putStrLn ("✗ FAILED: " <> msg)
  exitFailure

main :: IO ()
main = do
  cwd <- getCurrentDirectory
  let root = cwd </> "../.."
  poseRaw <- TIO.readFile (root <> "/resources/scripts/combat_presentation/svg-poses.json")
  stagingRaw <- TIO.readFile (root <> "/resources/scripts/combat_presentation/staging.json")
  fistRaw <- TIO.readFile (root <> "/resources/scripts/combat_actions/fist.json")
  swordRaw <- TIO.readFile (root <> "/resources/scripts/combat_actions/sword.json")
  effRaw <- TIO.readFile (root <> "/resources/scripts/combat_actions/effects.json")

  poseLib <- case parsePoseLibrary poseRaw of
    Left err -> putStrLn ("Pose parse failed: " <> err) >> exitFailure
    Right l -> pure l

  catalog <- case parseActionCatalog stagingRaw [fistRaw, swordRaw, effRaw] of
    Left err -> putStrLn ("Catalog parse failed: " <> err) >> exitFailure
    Right c -> pure c

  let attacks = filter (isTravelMotion . adActorMotion) (M.elems (acActions catalog))
  assertBool "loaded attack actions" (length attacks >= 10)
  putStrLn ("✓ Loaded " <> show (M.size (acActions catalog)) <> " actions & " <> show (length (allPoseIds poseLib)) <> " SVG poses in Haskell")

  -- 1. Every contact lands the fist, foot or blade tip on the target within 1e-6!
  forM_ attacks $ \act -> do
    let ev = CombatEvt "normal" "行者" "守擂人" "script" (adLabel act) "" 0 (Just 18) Nothing ResHit [] (adId act) [] Nothing (Just (adDurationMs act)) Nothing
        tl = resolveCombatTimeline catalog ev 1 SidePlayer SideEnemy (adLabel act) ProfileFemale ProfileMale (adStyle act) StyleSword
        pinned = filter (isJust . pkPin) (raPoseKeys (tlActor tl))
    forM_ (zip [0 :: Int ..] (tlHits tl)) $ \(idx, hit) -> do
      let key = pinned !! idx
          pose = sampleSvgPose poseLib (Just tl) SidePlayer (rhAtMs hit) (adStyle act) "idle" False
          pin = reachPointAt tl (rhAtMs hit)
          (lx, ly) = if pin == PinFoot then spFoot pose else spHand pose
          bladeLen = if pin == PinBlade then svgSwordLength else 0.0
          (ox, oy, _) = actorOffsetAt tl (rhAtMs hit)
          wx = ox + lx + bladeLen * cos (spBlade pose * pi / 180.0)
          wy = oy + ly + bladeLen * sin (spBlade pose * pi / 180.0)
          expX = fromMaybe (chReach (tlChoreography tl)) (pkReach key)
          expY = fromMaybe (chContactY (tlChoreography tl)) (pkContactY key) - 176.0
      assertBool (T.unpack (adId act) <> " hit " <> show idx <> " reach") (abs (wx - expX) < 1e-5)
      assertBool (T.unpack (adId act) <> " hit " <> show idx <> " height") (abs (wy - expY) < 1e-5)
  putStrLn "✓ Every contact lands fist, foot or blade tip on target (< 1e-5)"

  -- 2. Server durations scale the whole presentation and dash
  forM_ attacks $ \act ->
    forM_ [0.6, 1.8 :: Double] $ \factor -> do
      let scaledDur = fromIntegral (jsRound (adDurationMs act * factor))
          ev = CombatEvt "normal" "行者" "守擂人" "script" (adLabel act) "" 0 (Just 18) Nothing ResHit [] (adId act) [] Nothing (Just scaledDur) Nothing
          tl = resolveCombatTimeline catalog ev 1 SidePlayer SideEnemy (adLabel act) ProfileFemale ProfileMale (adStyle act) StyleSword
      assertBool "duration scaling" (abs ((tlDurationMs tl - raActionDelayMs (tlActor tl)) - scaledDur) < 1e-6)
      assertBool "positive dash delay" (raActionDelayMs (tlActor tl) > 0)
      assertBool "hits inside window" (all (\h -> rhAtMs h > raActionDelayMs (tlActor tl) && rhAtMs h < tlDurationMs tl) (tlHits tl))
  putStrLn "✓ Server durations scale presentation and dash cleanly"

  -- 3. Multi-hit damage splits by share and sums to server total
  let comboAct = battleActionFor catalog "rig.fist.combo_a" StyleFist
      comboEv = CombatEvt "normal" "行者" "守擂人" "script" (adLabel comboAct) "" 0 (Just 18) Nothing ResHit [] "rig.fist.combo_a" [] Nothing Nothing Nothing
      comboTl = resolveCombatTimeline catalog comboEv 1 SidePlayer SideEnemy "连环三捶" ProfileFemale ProfileMale StyleFist StyleSword
  assertBool "combo_a share split [5,4,9]" (map rhDamage (tlHits comboTl) == [Just 5, Just 4, Just 9])
  assertBool "combo_a float texts" (map rhFloatText (tlHits comboTl) == ["-5", "-4", "-9"])
  putStrLn "✓ Multi-hit damage splits by share ([5, 4, 9]) and sums to server total"
