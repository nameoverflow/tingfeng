{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Tingfeng.UiCanvas
  ( UiOutput (..),
    buildUiOverlay,
  )
where

import Data.Char (ord)
import Data.List (find)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy.Builder as B
import qualified Data.Text.Lazy.Builder.Int as BI
import Tingfeng.Battle (ResolvedTimeline (..))
import Tingfeng.Catalog (ActionDef (..), ActionCatalog (..))
import Tingfeng.I18n
import Tingfeng.Pose (LookStyle (..))
import Tingfeng.Protocol
import Tingfeng.State

data UiOutput = UiOutput
  { uoBuilder :: !B.Builder,
    uoHits :: ![CanvasHitbox],
    uoScrollZones :: ![ScrollZone],
    uoLogMaxScroll :: !Double,
    uoDrawerMaxScroll :: !Double,
    uoOnboardMaxScroll :: !Double,
    uoNpcMaxScroll :: !Double,
    uoCmdCount :: !Int
  }

emptyUi :: UiOutput
emptyUi = UiOutput mempty [] [] 0 0 0 0 0

-- Compact numeric & text formatters matching Render.hs / app.js

f1 :: Double -> B.Builder
f1 !v =
  let !n = round (v * 10.0) :: Int
      !a = abs n
      (!q, !r) = a `quotRem` 10
      sign = if n < 0 then B.singleton '-' else mempty
   in sign <> BI.decimal q <> B.singleton '.' <> BI.decimal r

f2 :: Double -> B.Builder
f2 !v =
  let !n = round (v * 100.0) :: Int
      !a = abs n
      (!q, !r) = a `quotRem` 100
      sign = if n < 0 then B.singleton '-' else mempty
      pad = if r < 10 then B.singleton '0' else mempty
   in sign <> BI.decimal q <> B.singleton '.' <> pad <> BI.decimal r

san :: Text -> B.Builder
san = B.fromText . T.map (\c -> if c == '|' || c == '\n' || c == '\r' then ' ' else c)

cmdRect :: Double -> Double -> Double -> Double -> Double -> Text -> Text -> Double -> Double -> B.Builder
cmdRect x y w h r fill bd lw al =
  "RR|" <> f1 x <> "|" <> f1 y <> "|" <> f1 w <> "|" <> f1 h <> "|" <> f1 r <> "|"
    <> B.fromText fill <> "|" <> B.fromText bd <> "|" <> f1 lw <> "|" <> f2 al <> "\n"

cmdLine :: Double -> Double -> Double -> Double -> Double -> Text -> Double -> Bool -> B.Builder
cmdLine x1 y1 x2 y2 lw col al dashed =
  "LN|" <> f1 x1 <> "|" <> f1 y1 <> "|" <> f1 x2 <> "|" <> f1 y2 <> "|"
    <> f1 lw <> "|" <> B.fromText col <> "|" <> f2 al <> "|" <> (if dashed then "1" else "0") <> "\n"

cmdCirc :: Double -> Double -> Double -> Text -> Text -> Double -> Double -> B.Builder
cmdCirc cx cy r fill bd lw al =
  "CI|" <> f1 cx <> "|" <> f1 cy <> "|" <> f1 r <> "|" <> B.fromText fill <> "|" <> B.fromText bd <> "|" <> f1 lw <> "|" <> f2 al <> "\n"

cmdTx :: Double -> Double -> Double -> Text -> Text -> Text -> Double -> Text -> B.Builder
cmdTx x y sz wt align col al txt =
  "TX|" <> f1 x <> "|" <> f1 y <> "|" <> f1 sz <> "|" <> B.fromText wt <> "|" <> B.fromText align <> "|" <> B.fromText col <> "|" <> f2 al <> "|" <> san txt <> "\n"

cmdSerif :: Double -> Double -> Double -> Text -> Text -> Text -> Double -> Text -> B.Builder
cmdSerif x y sz wt align col al txt =
  "TXS|" <> f1 x <> "|" <> f1 y <> "|" <> f1 sz <> "|" <> B.fromText wt <> "|" <> B.fromText align <> "|" <> B.fromText col <> "|" <> f2 al <> "|" <> san txt <> "\n"

cmdImg :: Text -> Double -> Double -> Double -> Double -> Double -> B.Builder
cmdImg key x y w h r =
  "IMG|" <> B.fromText key <> "|" <> f1 x <> "|" <> f1 y <> "|" <> f1 w <> "|" <> f1 h <> "|" <> f1 r <> "\n"

cmdClip :: Double -> Double -> Double -> Double -> B.Builder
cmdClip x y w h = "CLIP|" <> f1 x <> "|" <> f1 y <> "|" <> f1 w <> "|" <> f1 h <> "\n"

cmdUnclip :: B.Builder
cmdUnclip = "UNCLIP\n"

cmdInput :: Text -> Double -> Double -> Double -> Double -> Text -> B.Builder
cmdInput inpId x y w h val =
  "INPUT|" <> B.fromText inpId <> "|" <> f1 x <> "|" <> f1 y <> "|" <> f1 w <> "|" <> f1 h <> "|" <> san val <> "\n"

-- CJK-aware text measurement & word wrapping

charWidthFactor :: Char -> Double
charWidthFactor c
  | ord c > 0x2E7F = 1.02
  | c == ' ' || c == 'i' || c == 'l' || c == '1' || c == '.' || c == ',' || c == ':' = 0.36
  | c >= 'A' && c <= 'Z' = 0.68
  | otherwise = 0.56

textWidth :: Double -> Text -> Double
textWidth sz = T.foldl' (\acc c -> acc + charWidthFactor c * sz) 0.0

truncateText :: Double -> Double -> Text -> Text
truncateText maxW sz txt
  | textWidth sz txt <= maxW = txt
  | otherwise = go (T.unpack txt) 0.0 []
  where
    limit = max 8.0 (maxW - sz * 0.9)
    go [] _ acc = T.pack (reverse acc)
    go (c : cs) w acc =
      let cw = charWidthFactor c * sz
       in if w + cw > limit
            then T.pack (reverse acc) <> "…"
            else go cs (w + cw) (c : acc)

wrapText :: Double -> Double -> Text -> [Text]
wrapText maxW sz raw =
  concatMap wrapPara (T.splitOn "\n" raw)
  where
    limit = max (sz * 2.0) maxW
    wrapPara p
      | T.null p = [""]
      | otherwise = go (T.unpack p) 0.0 [] []
    go [] _ cur linesAcc = reverse (T.pack (reverse cur) : linesAcc)
    go (c : cs) w cur linesAcc =
      let cw = charWidthFactor c * sz
       in if w + cw > limit && not (null cur)
            then go (c : cs) 0.0 [] (T.pack (reverse cur) : linesAcc)
            else go cs (w + cw) (c : cur) linesAcc

-- Woodblock Button & Meter Primitives

data BtnTone = ToneDefault | TonePrimary | ToneDanger | ToneJade | ToneGhost | ToneActive
  deriving (Eq)

drawBtn ::
  ClientModel ->
  Double ->
  Double ->
  Double ->
  Double ->
  Text ->
  Double ->
  BtnTone ->
  Bool ->
  HitTarget ->
  (B.Builder, [CanvasHitbox])
drawBtn m x y w h label fontSz tone disabled target =
  let hov = not disabled && cmHovered m == Just target
      (bg, bd, fg, lw) = case tone of
        TonePrimary ->
          if hov then ("#234a3e", "#946623", "#f7f1e3", 1.5) else ("#2b594b", "#1e3f35", "#f7f1e3", 1.3)
        ToneDanger ->
          if hov then ("#8f241b", "#6e1912", "#f7f1e3", 1.5) else ("#a32c22", "#7d2018", "#f7f1e3", 1.2)
        ToneJade ->
          if hov then ("#e4eee9", "#2b594b", "#1e4237", 1.5) else ("#eef4f0", "#2b594b", "#2b594b", 1.2)
        ToneActive ->
          ("#1e1a16", "#946623", "#f6f0e2", 1.5)
        ToneGhost ->
          if hov then ("#ebe2ce", "#8b7f6e", "#1e1a16", 1.1) else ("#f6f0e2", "#c8bca4", "#4a4136", 1.0)
        ToneDefault ->
          if hov then ("#ede4d0", "#946623", "#1e1a16", 1.4) else ("#f6f0e2", "#b8aa91", "#1e1a16", 1.1)
      al = if disabled then 0.45 else 0.98
      b =
        cmdRect x y w h 3 bg bd lw al
          <> cmdTx (x + w * 0.5) (y + h * 0.5 + fontSz * 0.35) fontSz "600" "center" fg al (truncateText (w - 10) fontSz label)
      hb = if disabled then [] else [CanvasHitbox x y w h target "pointer"]
   in (b, hb)

drawMeter :: Double -> Double -> Double -> Double -> Double -> Maybe Double -> Text -> Text -> Text -> B.Builder
drawMeter x y w h ratio mTrail fillCol trailCol labelTxt =
  let r = max 0.0 (min 1.0 ratio)
      track = cmdRect x y w h 2 "#dfd5be" "#c5b9a0" 0.8 0.96
      trailB = case mTrail of
        Just trR | trR > r + 0.005 ->
          cmdRect x y (w * max 0.0 (min 1.0 trR)) h 2 trailCol "" 0 0.72
        _ -> mempty
      fillB = if r > 0.002 then cmdRect x y (w * r) h 2 fillCol "" 0 0.96 else mempty
      lblB =
        if T.null labelTxt
          then mempty
          else
            if r >= 0.96
              then cmdTx (x + w - 5) (y + h * 0.5 + 3.6) 10 "700" "right" "#f7f1e3" 0.96 labelTxt
              else
                if r <= 0.62
                  then cmdTx (x + w - 5) (y + h * 0.5 + 3.6) 10 "700" "right" "#1e1a16" 0.96 labelTxt
                  else
                    let tw = textWidth 10 labelTxt + 8
                     in cmdRect (x + w - tw - 1) (y + 1) tw (h - 2) 2 "#f6f0e2" "" 0 0.86
                          <> cmdTx (x + w - 5) (y + h * 0.5 + 3.6) 10 "700" "right" "#1e1a16" 0.98 labelTxt
   in track <> trailB <> fillB <> lblB

drawScrollbar :: Double -> Double -> Double -> Double -> Double -> Double -> B.Builder
drawScrollbar x y h scrollPos maxScroll viewH
  | maxScroll <= 2.0 = mempty
  | otherwise =
      let totalH = viewH + maxScroll
          thumbH = max 24.0 (h * (viewH / max 1.0 totalH))
          thumbY = y + (h - thumbH) * (scrollPos / max 1.0 maxScroll)
       in cmdRect x y 4 h 2 "#dcd1ba" "" 0 0.45
            <> cmdRect x thumbY 4 thumbH 2 "#8b7f6e" "" 0 0.78

-- Top-level UI Orchestrator (100% Pure Haskell Canvas)

buildUiOverlay :: ClientModel -> UiOutput
buildUiOverlay m = case cmPage m of
  PagePoseSheet -> emptyUi
  PageBattleLab -> buildBattleLabUi m
  PageGame
    | not (cmConnected m) && not (cmInBattle m) -> buildOnboardingUi m
    | otherwise -> buildGameUi m

-- 1. Battle Lab Full-Canvas Controls (/battle-lab.html)

buildBattleLabUi :: ClientModel -> UiOutput
buildBattleLabUi m =
  let w = cmWidth m
      h = cmHeight m
      isMob = w <= 768.0
      (topB, topHits) = drawBattleTopBar m isMob 14.0
      acts = labActionOrder m
      curActId = if null acts then "rig.fist.punch_a" else acts !! (cmLabActionIdx m `mod` length acts)
      curActLbl = maybe curActId adLabel (M.lookup curActId (acActions (cmCatalog m)))
      outLbl = ["命中", "闪避", "招架", "效果"] !! (cmLabOutcomeIdx m `mod` 4)
      sideLbl = ["行者", "守擂人"] !! (cmLabSideIdx m `mod` 2)
      lookLbl = if cmLookStyle m == LookMaiden then "发髻披发" else "高马尾"

      dockW = min 900.0 (w - 24.0)
      dockH = if isMob then 128.0 else 86.0
      dockX = (w - dockW) * 0.5
      dockY = h - dockH - 12.0
      dockBg = cmdRect dockX dockY dockW dockH 3 "#f6f0e2" "#b8aa91" 1.2 0.96

      -- Row 1 buttons
      bx0 = dockX + 12.0
      by0 = dockY + 10.0
      (bDemo, hDemo) = drawBtn m bx0 by0 102 28 "播放完整交锋" 12 TonePrimary False (HitLab "demo" "" "" "" 0)
      (bPause, hPause) = drawBtn m (bx0 + 108) by0 56 28 (if cmLabPaused m then "继续" else "暂停") 12 ToneDefault False (HitLab "pause" (if cmLabPaused m then "false" else "true") "" "" 0)
      (bPrev, hPrev) = drawBtn m (bx0 + 170) by0 28 28 "‹" 14 ToneDefault False (HitUi "lab_cycle_action" "prev" "")
      actBoxW = if isMob then max 110 (dockW - 240) else 172
      actBox =
        cmdRect (bx0 + 202) by0 actBoxW 28 3 "#efe7d4" "#c5b9a0" 1.0 0.98
          <> cmdTx (bx0 + 202 + actBoxW * 0.5) (by0 + 18) 11.5 "600" "center" "#1e1a16" 1 (truncateText (actBoxW - 10) 11.5 curActLbl)
      (bNext, hNext) = drawBtn m (bx0 + 206 + actBoxW) by0 28 28 "›" 14 ToneDefault False (HitUi "lab_cycle_action" "next" "")

      r2x = if isMob then bx0 else bx0 + 240 + actBoxW
      r2y = if isMob then by0 + 34 else by0
      (bOut, hOut) = drawBtn m r2x r2y 56 28 outLbl 11.5 ToneDefault False (HitUi "lab_cycle_outcome" "" "")
      (bSide, hSide) = drawBtn m (r2x + 62) r2y 60 28 sideLbl 11.5 ToneDefault False (HitUi "lab_cycle_side" "" "")
      (bLook, hLook) = drawBtn m (r2x + 128) r2y 68 28 lookLbl 11.5 ToneDefault False (HitUi "toggle_look" "" "")
      (bOne, hOne) = drawBtn m (r2x + 202) r2y 82 28 "播放这一招" 11.5 ToneJade False (HitUi "lab_play_selected" "" "")

      -- Timeline scrubber row
      sy = dockY + dockH - 26.0
      dur = maybe 0.0 tlDurationMs (cmActiveTimeline m)
      elap = cmTimelineElapsedMs m
      tLbl = "时间轴 " <> T.pack (show (round elap :: Int)) <> " / " <> T.pack (show (round dur :: Int)) <> " ms"
      scX = dockX + 168.0
      scW = max 80.0 (dockW - 184.0)
      ratio = if dur > 0.1 then max 0.0 (min 1.0 (elap / dur)) else 0.0
      scrubB =
        cmdTx (dockX + 12) (sy + 9) 11.5 "600" "left" "#5c5346" 1 tLbl
          <> cmdRect scX (sy + 2) scW 8 2 "#dfd5be" "#b8aa91" 0.8 1
          <> cmdRect scX (sy + 2) (scW * ratio) 8 2 "#946623" "" 0 0.95
          <> cmdCirc (scX + scW * ratio) (sy + 6) 6 "#a32c22" "#f6f0e2" 1.5 1
      scrubHit = CanvasHitbox (scX - 6) (sy - 6) (scW + 12) 24 (HitLabScrub scX scW) "ew-resize"
      dockSwallow = CanvasHitbox dockX dockY dockW dockH HitSwallow "default"
   in emptyUi
        { uoBuilder = topB <> dockBg <> bDemo <> bPause <> bPrev <> actBox <> bNext <> bOut <> bSide <> bLook <> bOne <> scrubB,
          uoHits = topHits <> [dockSwallow] <> hDemo <> hPause <> hPrev <> hNext <> hOut <> hSide <> hLook <> hOne <> [scrubHit],
          uoCmdCount = 60
        }

-- 2. Onboarding & Character Creation Full-Canvas Scroll Card

buildOnboardingUi :: ClientModel -> UiOutput
buildOnboardingUi m =
  let w = cmWidth m
      h = cmHeight m
      zh = cmLocale m == Zh
      -- Minimal top header
      hdrH = 50.0
      hdrBg =
        cmdRect 0 0 w hdrH 0 "#f5efe1" "" 0 0.96
          <> cmdLine 0 hdrH w hdrH 1 "#c6baa3" 0.9 False
          <> cmdRect 16 11 28 28 3 "#a32c22" "#7d2018" 1 0.96
          <> cmdSerif 30 30 16 "700" "center" "#f7f1e3" 1 "武"
          <> cmdSerif 54 31 18 "700" "left" "#1e1a16" 1 (if zh then "听风录" else "Tingfeng")
      (bLoc, hLoc) = drawBtn m (w - 54) 11 40 28 (if zh then "EN" else "中") 11.5 ToneGhost False (HitUi "toggle_locale" "" "")

      -- Centered Xuan paper scroll card (stays cleanly above iOS software keyboard when viewport shrinks)
      cardW = min 500.0 (w - 28.0)
      cardMaxH = max 180.0 (h - hdrH - 16.0)
      cardX = (w - cardW) * 0.5
      isCreate = cmLoginMode m == "create"
      pad = if h < 480.0 then 14.0 else 20.0
      innerW = cardW - pad * 2

      -- Mode tabs
      tabW = (innerW - 8) * 0.5
      tabY = if h < 480.0 then 12.0 else 18.0
      contentStartY = tabY + (if h < 480.0 then 36.0 else 42.0)

      (_, _, contentH) =
        if not isCreate
          then buildLoginBody m zh cardX pad innerW contentStartY
          else buildCreateBody m zh cardX pad innerW contentStartY

      cardH = min cardMaxH (max 210.0 (contentStartY + contentH + 14.0))
      cardY = hdrH + max 8.0 ((h - hdrH - cardH) * (if h < 480.0 then 0.25 else 0.45))

      -- Recompute in screen coords with scroll
      viewH = cardH - contentStartY - 12.0
      maxScroll = max 0.0 (contentH - viewH)
      scrollY = max 0.0 (min maxScroll (cmOnboardScroll m))
      (bodyB2, bodyHits2, _) =
        if not isCreate
          then buildLoginBody m zh cardX pad innerW (cardY + contentStartY - scrollY)
          else buildCreateBody m zh cardX pad innerW (cardY + contentStartY - scrollY)

      cardFrame =
        cmdRect cardX cardY cardW cardH 4 "#f6f0e2" "#b8aa91" 1.3 0.98
          <> cmdRect cardX cardY cardW 3.5 0 "#a32c22" "" 0 0.92
      (bTabL, hTabL) = drawBtn m (cardX + pad) (cardY + tabY) tabW 32 (if zh then "登录江湖" else "Sign In") 13 (if not isCreate then ToneActive else ToneGhost) False (HitUi "login_mode" "login" "")
      (bTabC, hTabC) = drawBtn m (cardX + pad + tabW + 8) (cardY + tabY) tabW 32 (if zh then "创建角色" else "New Character") 13 (if isCreate then ToneActive else ToneGhost) False (HitUi "login_mode" "create" "")

      clipY = cardY + contentStartY - 2
      clipH = max 40.0 (cardH - contentStartY - 10)
      clippedBody = cmdClip (cardX + 4) clipY (cardW - 8) clipH <> bodyB2 <> cmdUnclip
      sb = drawScrollbar (cardX + cardW - 8) clipY clipH scrollY maxScroll viewH
      visBodyHits = filter (\hb -> chY hb + chH hb >= clipY && chY hb <= clipY + clipH) bodyHits2
      swallow = CanvasHitbox cardX cardY cardW cardH HitSwallow "default"
      sZone = ScrollZone cardX clipY cardW clipH ScrollOnboard
   in emptyUi
        { uoBuilder = hdrBg <> bLoc <> cardFrame <> bTabL <> bTabC <> clippedBody <> sb,
          uoHits = hLoc <> [swallow] <> hTabL <> hTabC <> visBodyHits,
          uoScrollZones = [sZone],
          uoOnboardMaxScroll = maxScroll,
          uoCmdCount = 90
        }

buildLoginBody :: ClientModel -> Bool -> Double -> Double -> Double -> Double -> (B.Builder, [CanvasHitbox], Double)
buildLoginBody m zh cardX pad innerW y0 =
  let x0 = cardX + pad
      titleB = cmdSerif x0 (y0 + 18) 20 "700" "left" "#1e1a16" 1 (if zh then "重入江湖" else "Return to Jianghu")
      subLines = wrapText innerW 12.5 (if zh then "输入角色名号续接存档，或切换至「创建角色」定制身世与先天根骨。" else "Enter your character name to continue your journey.")
      subB = mconcat [cmdTx x0 (y0 + 40 + fromIntegral i * 18) 12.5 "400" "left" "#5c5346" 1 ln | (i, ln) <- zip [0 :: Int ..] subLines]
      yInp = y0 + 44 + fromIntegral (length subLines) * 18
      inpW = innerW - 102
      focused = cmFocusedInput m == Just "login"
      inpBd = if focused then "#946623" else "#b8aa91"
      uTxt = cmUsername m
      blink = focused && ((floor (cmClockMs m / 520.0) :: Int) `mod` 2 == 0)
      dispTxt = if T.null uTxt then (if zh then "点击输入角色名号…" else "Character Name…") else uTxt
      dispCol = if T.null uTxt then "#8b7f6e" else "#1e1a16"
      caretX = x0 + 10 + (if T.null uTxt then 0 else textWidth 13.5 uTxt)
      inpB =
        cmdRect x0 yInp inpW 36 3 "#fcf9f2" inpBd (if focused then 1.8 else 1.1) 1
          <> cmdTx (x0 + 10) (yInp + 23) 13.5 "500" "left" dispCol 1 (truncateText (inpW - 20) 13.5 dispTxt)
          <> (if blink then cmdLine (min (x0 + inpW - 8) caretX) (yInp + 8) (min (x0 + inpW - 8) caretX) (yInp + 28) 1.5 "#1e1a16" 0.9 False else mempty)
          <> cmdInput "login" x0 yInp inpW 36 uTxt
      inpHit = CanvasHitbox x0 yInp inpW 36 (HitFocusInput "login") "text"
      passFlag = if cmDevReset m then "reset" else ""
      (bGo, hGo) = drawBtn m (x0 + inpW + 8) yInp 94 36 (if cmConnecting m then (if zh then "入世中…" else "Joining…") else (if zh then "踏入江湖" else "Enter")) 13 TonePrimary (cmConnecting m) (HitUi "login_submit" uTxt passFlag)

      yChk = yInp + 48
      chkB =
        cmdRect x0 yChk 16 16 2 (if cmDevReset m then "#2b594b" else "#fcf9f2") "#8b7f6e" 1.1 1
          <> (if cmDevReset m then cmdTx (x0 + 8) (yChk + 12.5) 12 "700" "center" "#f7f1e3" 1 "✓" else mempty)
          <> cmdTx (x0 + 24) (yChk + 12.5) 12 "400" "left" "#5c5346" 1 (if zh then "测试重开存档（需 MUD_DEV_MODE=1）" else "Dev reset save")
      chkHit = CanvasHitbox x0 (yChk - 4) 240 24 (HitUi "toggle_dev_reset" "" "") "pointer"

      (errB, errH) = case cmLastError m of
        Nothing -> (mempty, 0)
        Just e ->
          let els = wrapText innerW 12 e
           in (mconcat [cmdTx x0 (yChk + 32 + fromIntegral i * 17) 12 "600" "left" "#a32c22" 1 ln | (i, ln) <- zip [0 :: Int ..] els], fromIntegral (length els) * 17 + 12)
   in (titleB <> subB <> inpB <> bGo <> chkB <> errB, [inpHit] <> hGo <> [chkHit], (yChk + 30 + errH) - y0)

buildCreateBody :: ClientModel -> Bool -> Double -> Double -> Double -> Double -> (B.Builder, [CanvasHitbox], Double)
buildCreateBody m zh cardX pad innerW y0 =
  let x0 = cardX + pad
   in case cmCreationCfg m of
        Nothing ->
          let msg = cmdTx x0 (y0 + 22) 13 "400" "left" "#5c5346" 1 (if zh then "正在向服务端读取身世配置…" else "Loading creation config…")
              (bR, hR) = drawBtn m x0 (y0 + 40) 96 32 (if zh then "重试读取" else "Retry") 12.5 ToneDefault False (HitUi "request_creation_cfg" "" "")
           in (msg <> bR, hR, 88)
        Just cfg ->
          let step = cmCreateStep m
              cc = cmCreateChoice m
              stepLabels = if zh then ["名号", "性别", "出身", "幼年", "后来", "预览"] else ["Name", "Sex", "Origin", "Early", "Youth", "Done"]
              sw = (innerW - 25) / 6.0
              (stBs, stHs) =
                unzip
                  [ drawBtn m (x0 + fromIntegral idx * (sw + 5)) y0 sw 26 lbl 11 (if step == idx then ToneActive else ToneGhost) False (HitUi "create_step" (T.pack (show idx)) "")
                    | (idx, lbl) <- zip [0 :: Int ..] stepLabels
                  ]
              y1 = y0 + 40
              (sb, sh, shH) = case step of
                0 ->
                  let tB = cmdSerif x0 (y1 + 16) 17 "700" "left" "#1e1a16" 1 (if zh then "立定名号" else "Choose a Name")
                      inpW = innerW - 92
                      focused = cmFocusedInput m == Just "login"
                      uTxt = cmUsername m
                      disp = if T.null uTxt then (if zh then "如：沈青蝉" else "Name") else uTxt
                      inpB =
                        cmdRect x0 (y1 + 30) inpW 36 3 "#fcf9f2" (if focused then "#946623" else "#b8aa91") 1.3 1
                          <> cmdTx (x0 + 10) (y1 + 53) 13.5 "500" "left" (if T.null uTxt then "#8b7f6e" else "#1e1a16") 1 disp
                          <> cmdInput "login" x0 (y1 + 30) inpW 36 uTxt
                      inpHit = CanvasHitbox x0 (y1 + 30) inpW 36 (HitFocusInput "login") "text"
                      (bNx, hNx) = drawBtn m (x0 + inpW + 8) (y1 + 30) 84 36 (if zh then "下一步" else "Next") 12.5 TonePrimary False (HitUi "create_step" "1" "")
                   in (tB <> inpB <> bNx, [inpHit] <> hNx, 82)
                1 ->
                  let tB = cmdSerif x0 (y1 + 16) 17 "700" "left" "#1e1a16" 1 ((if T.null (cmUsername m) then "无名客" else cmUsername m) <> (if zh then " 是：" else ":"))
                      (bs, hs) =
                        unzip
                          [ drawBtn m x0 (y1 + 30 + fromIntegral i * 44) innerW 36 glbl 13.5 (if ccGender cc == gid then ToneJade else ToneDefault) False (HitUi "create_pick" "gender" gid)
                            | (i, (gid, glbl)) <- zip [0 :: Int ..] (cfgGenders cfg)
                          ]
                   in (tB <> mconcat bs, concat hs, 36 + fromIntegral (length (cfgGenders cfg)) * 44)
                n | n >= 2 && n <= 4 ->
                  let (field, opts, title) = case n of
                        2 -> ("origin", cfgOrigins cfg, if zh then "出身来历" else "Origin")
                        3 -> ("childhood1", cfgChildhood1 cfg, if zh then "幼年经历" else "Childhood")
                        _ -> ("childhood2", cfgChildhood2 cfg, if zh then "后来际遇" else "Youth")
                      curId = case n of 2 -> ccOrigin cc; 3 -> ccChildhood1 cc; _ -> ccChildhood2 cc
                      pName = if T.null (T.strip (cmUsername m)) then "无名客" else T.strip (cmUsername m)
                      tB = cmdSerif x0 (y1 + 16) 17 "700" "left" "#1e1a16" 1 title
                      renderOpt accY o =
                        let storyLines = wrapText (innerW - 24) 11.5 (T.replace "{name}" pName (coStory o))
                            oh = 32 + fromIntegral (length storyLines) * 16 + 10
                            sel = curId == coId o
                            tgt = HitUi "create_pick" field (coId o)
                            hov = cmHovered m == Just tgt
                            bg = if sel then "#ebe3cf" else if hov then "#f2ead8" else "#faf5e9"
                            bd = if sel then "#946623" else if hov then "#2b594b" else "#c8bca4"
                            ob =
                              cmdRect x0 accY innerW oh 3 bg bd (if sel then 1.6 else 1.0) 0.98
                                <> cmdTx (x0 + 12) (accY + 20) 13 "700" "left" "#1e1a16" 1 (coLabel o)
                                <> mconcat [cmdTx (x0 + 12) (accY + 38 + fromIntegral i * 16) 11.5 "400" "left" "#5c5346" 1 ln | (i, ln) <- zip [0 :: Int ..] storyLines]
                         in (accY + oh + 8, ob, CanvasHitbox x0 accY innerW oh tgt "pointer")
                      (endY, obs, ohs) = foldl' (\(ay, bs, hs) o -> let (ny, b, h1) = renderOpt ay o in (ny, bs <> b, hs <> [h1])) (y1 + 30, mempty, []) opts
                   in (tB <> obs, ohs, endY - y1)
                _ ->
                  let findOpt nid = find (\o -> coId o == nid)
                      bOrig = maybe emptyBonus coBonus (findOpt (ccOrigin cc) (cfgOrigins cfg))
                      bC1 = maybe emptyBonus coBonus (findOpt (ccChildhood1 cc) (cfgChildhood1 cfg))
                      bC2 = maybe emptyBonus coBonus (findOpt (ccChildhood2 cc) (cfgChildhood2 cfg))
                      tot = foldl' addBonus (cfgBaseStats cfg) [bOrig, bC1, bC2]
                      tB = cmdSerif x0 (y1 + 16) 17 "700" "left" "#1e1a16" 1 (if zh then "入世预览" else "Character Preview")
                      pCard =
                        cmdRect x0 (y1 + 28) innerW 84 3 "#efe7d4" "#c5b9a0" 1.1 0.98
                          <> cmdImg (portraitScoreFile (cbAppearance tot)) (x0 + 10) (y1 + 38) 64 64 3
                          <> cmdSerif (x0 + 86) (y1 + 58) 16 "700" "left" "#1e1a16" 1 (if T.null (cmUsername m) then "无名客" else cmUsername m)
                          <> cmdTx (x0 + 86) (y1 + 80) 12 "500" "left" "#5c5346" 1
                               ("臂力 " <> T.pack (show (cbStrength tot)) <> " · 身法 " <> T.pack (show (cbAgilityValue tot)) <> " · 根骨 " <> T.pack (show (cbVitality tot)))
                          <> cmdTx (x0 + 86) (y1 + 98) 12 "500" "left" "#2b594b" 1
                               ("内力 " <> T.pack (show (cbMaxQiBonus tot)) <> " · 容貌 " <> T.pack (show (max 0 (min 10 (cbAppearance tot)))))
                      passFlag = if cmDevReset m then "reset" else ""
                      (bGo, hGo) = drawBtn m x0 (y1 + 124) innerW 38 (if zh then "确认踏入江湖" else "Create & Enter") 13.5 TonePrimary (cmConnecting m) (HitUi "create_submit" (cmUsername m) passFlag)
                   in (tB <> pCard <> bGo, hGo, 174)
           in (mconcat stBs <> sb, concat stHs <> sh, 40 + shH)

-- 3. Connected Main Game Full-Canvas UI

buildGameUi :: ClientModel -> UiOutput
buildGameUi m =
  let w = cmWidth m
      h = cmHeight m
      isMob = w <= 768.0
      (hdrB, hdrHits) = if isMob then drawMobileHeader m else drawDesktopHeader m
      (navB, navHits) = if isMob then drawMobileTabbar m else (mempty, [])

      -- Center workspace (hidden on mobile when another tab is active)
      showCenter = not isMob || cmMobileTab m == "world"
      (centerB, centerHits, centerZones, logMaxS, npcMaxS)
        | not showCenter = (mempty, [], [], cmLogMaxScroll m, 0)
        | cmInBattle m =
            let (btB, btH) = drawBattleTopBar m isMob (if isMob then 62.0 else 64.0)
                (skB, skH, _) = drawBattleSkills m isMob (if isMob then h - 180.0 else h - 144.0)
                dockH = if isMob then 112.0 else 124.0
                dockY = if isMob then h - 54.0 - dockH - 6.0 else h - dockH - 12.0
                (lgB, lgH, lgZ, lgM) = drawMessageDock m isMob dockY dockH True
             in (btB <> skB <> lgB, btH <> skH <> lgH, lgZ, lgM, 0)
        | otherwise =
            let (rmB, rmH) = drawRoomCard m isMob
                (zmB, zmH) = drawMapControls m isMob
                dockH = if isMob then 164.0 else 196.0
                dockY = if isMob then h - 54.0 - dockH - 6.0 else h - dockH - 12.0
                (lgB, lgH, lgZ, lgM) = drawMessageDock m isMob dockY dockH False
                (npcB, npcH, npcZ, npcM) = drawNpcModal m isMob
             in (rmB <> zmB <> lgB <> npcB, rmH <> zmH <> lgH <> npcH, lgZ <> npcZ, lgM, npcM)

      -- Drawer (Desktop slide-over with dim backdrop, or Mobile full tab)
      activeDrawer =
        if isMob
          then if cmMobileTab m == "world" then "" else cmMobileTab m
          else cmDesktopDrawer m
      (drB, drHits, drZones, drMaxS, drLogMax) =
        if T.null activeDrawer
          then (mempty, [], [], 0, logMaxS)
          else
            if isMob && activeDrawer == "log"
              then
                let (lb, lh, lz, lm) = drawMessageDock m True 58.0 (h - 114.0) False
                 in (lb, lh, lz, 0, lm)
              else
                let (db, dh, dz, dm) = drawSideDrawer m isMob activeDrawer
                 in (db, dh, dz, dm, logMaxS)
   in UiOutput
        { uoBuilder = hdrB <> centerB <> drB <> navB,
          uoHits = hdrHits <> centerHits <> drHits <> navHits,
          uoScrollZones = centerZones <> drZones,
          uoLogMaxScroll = drLogMax,
          uoDrawerMaxScroll = drMaxS,
          uoOnboardMaxScroll = 0,
          uoNpcMaxScroll = npcMaxS,
          uoCmdCount = 140
        }

-- Desktop Header (52px Song-dynasty Xuan paper bar)

drawDesktopHeader :: ClientModel -> (B.Builder, [CanvasHitbox])
drawDesktopHeader m =
  let w = cmWidth m
      zh = cmLocale m == Zh
      st = cmStats m
      (presHp, presMaxHp, presQi, presMaxQi) = presentedVitals m
      hpPct = fromIntegral presHp / fromIntegral (max 1 presMaxHp)
      qiPct = fromIntegral presQi / fromIntegral (max 1 presMaxQi)

      bg =
        cmdRect 0 0 w 52 0 "#f5efe1" "" 0 0.96
          <> cmdLine 0 52 w 52 1 "#c6baa3" 0.95 False
      swallow = CanvasHitbox 0 0 w 52 HitSwallow "default"

      -- Left: Player portrait plaque
      pillW = 216.0
      pillActive = cmDesktopDrawer m == "character"
      pillTgt = HitUi "desktop_drawer" "character" ""
      pillHov = cmHovered m == Just pillTgt
      pillB =
        cmdRect 14 7 pillW 38 3 (if pillActive then "#e9dfc9" else if pillHov then "#efe6d2" else "#faf5e9") (if pillActive then "#946623" else "#c5b9a0") (if pillActive then 1.5 else 1.0) 1
          <> cmdImg (portraitScoreFile (psAppearance st)) 19 11 30 30 2
          <> cmdTx 56 21 12.5 "700" "left" "#1e1a16" 1 (truncateText 96 12.5 (cmUsername m))
          <> cmdRect 56 27 88 4.5 1.5 "#dfd5be" "" 0 1
          <> cmdRect 56 27 (88 * max 0 (min 1 hpPct)) 4.5 1.5 "#a32c22" "" 0 1
          <> cmdRect 56 34 88 4.5 1.5 "#dfd5be" "" 0 1
          <> cmdRect 56 34 (88 * max 0 (min 1 qiPct)) 4.5 1.5 "#2b594b" "" 0 1
          <> cmdTx (14 + pillW - 8) 30 11 "700" "right" "#5c5346" 1 (T.pack (show presHp) <> "/" <> T.pack (show presQi))
      pillHit = CanvasHitbox 14 7 pillW 38 pillTgt "pointer"

      -- Busy training chip (with live countdown)
      (busyB, busyH) = case psBusy st of
        Just bi | not (cmInBattle m) ->
          let ageS = max 0.0 ((cmClockMs m - cmStatsSyncedAtMs m) / 1000.0)
              remS = max 0.0 (biSeconds bi - ageS)
              tot = biCompleted bi + biRemaining bi
              tName = fromMaybe (biTarget bi) (fmap aiName (find (\a -> aiId a == biTarget bi) (cmArts m)))
              lbl = tr (cmLocale m) ("training.action." <> biAction bi) <> " " <> tName <> " " <> T.pack (show (biCompleted bi)) <> "/" <> T.pack (show tot) <> " · " <> T.pack (show (ceiling remS :: Int)) <> "s"
              bw = min 240.0 (textWidth 11.5 lbl + 20)
           in drawBtn m (14 + pillW + 10) 11 bw 30 lbl 11.5 ToneJade False (HitUi "desktop_drawer" "arts" "")
        _ -> (mempty, [])

      -- Right nav buttons
      activeQ = length (filter (not . qiCompleted) (cmQuests m))
      (bArts, hArts) = drawBtn m (w - 198) 11 62 30 (if zh then "武学" else "Arts") 12.5 (if cmDesktopDrawer m == "arts" then ToneActive else ToneDefault) False (HitUi "desktop_drawer" "arts" "")
      (bQuests, hQuests) = drawBtn m (w - 128) 11 66 30 (if zh then "任务" else "Quests") 12.5 (if cmDesktopDrawer m == "quests" then ToneActive else ToneDefault) False (HitUi "desktop_drawer" "quests" "")
      qDot = if activeQ > 0 then cmdCirc (w - 69) 17 3.2 "#a32c22" "" 0 1 else mempty
      (bLoc, hLoc) = drawBtn m (w - 54) 11 40 30 (if zh then "EN" else "中") 11.5 ToneGhost False (HitUi "toggle_locale" "" "")
   in (bg <> pillB <> busyB <> bArts <> bQuests <> qDot <> bLoc, [swallow, pillHit] <> busyH <> hArts <> hQuests <> hLoc)

-- Mobile Header (56px)

drawMobileHeader :: ClientModel -> (B.Builder, [CanvasHitbox])
drawMobileHeader m =
  let w = cmWidth m
      zh = cmLocale m == Zh
      (presHp, presMaxHp, presQi, presMaxQi) = presentedVitals m
      hpPct = fromIntegral presHp / fromIntegral (max 1 presMaxHp)
      qiPct = fromIntegral presQi / fromIntegral (max 1 presMaxQi)
      mName = currentMapName m
      titleTxt
        | cmInBattle m = maybe (if zh then "交锋" else "Battle") (cbName . bsEnemy) (cmBattleSnap m)
        | not (T.null mName) && mName /= cmRoomName m && not (T.null (cmRoomName m)) = mName <> " · " <> cmRoomName m
        | not (T.null (cmRoomName m)) = cmRoomName m
        | otherwise = if zh then "听风录" else "Tingfeng"

      bg =
        cmdRect 0 0 w 56 0 "#f5efe1" "" 0 0.97
          <> cmdLine 0 56 w 56 1 "#c6baa3" 0.95 False
          <> cmdSerif 12 27 15 "700" "left" "#1e1a16" 1 (truncateText (w - 144) 15 titleTxt)
      swallow = CanvasHitbox 0 0 w 56 HitSwallow "default"

      (bVit, hVit) = drawBtn m (w - 126) 8 78 26 (T.pack (show presHp) <> "/" <> T.pack (show presQi)) 11 ToneDefault False (HitUi "mobile_tab" "character" "")
      (bLoc, hLoc) = drawBtn m (w - 42) 8 32 26 (if zh then "EN" else "中") 11 ToneGhost False (HitUi "toggle_locale" "" "")

      barW = (w - 30) * 0.5
      bars =
        cmdRect 12 41 barW 6 2 "#dfd5be" "" 0 1
          <> cmdRect 12 41 (barW * max 0 (min 1 hpPct)) 6 2 "#a32c22" "" 0 1
          <> cmdRect (18 + barW) 41 barW 6 2 "#dfd5be" "" 0 1
          <> cmdRect (18 + barW) 41 (barW * max 0 (min 1 qiPct)) 6 2 "#2b594b" "" 0 1
   in (bg <> bVit <> bLoc <> bars, [swallow] <> hVit <> hLoc)

-- Mobile Bottom Tabbar (54px with Crisp Canvas Vector Icons & Status Dots)

drawMobileTabbar :: ClientModel -> (B.Builder, [CanvasHitbox])
drawMobileTabbar m =
  let w = cmWidth m
      h = cmHeight m
      y0 = h - 54.0
      zh = cmLocale m == Zh
      tw = w / 5.0
      activeQ = length (filter (not . qiCompleted) (cmQuests m))
      ageS = max 0.0 ((cmClockMs m - cmStatsSyncedAtMs m) / 1000.0)
      liveInj = max 0 (psInjuredSeconds (cmStats m) - floor ageS)

      tabs =
        [ ("world", if zh then (if cmInBattle m then "交锋" else "江湖") else (if cmInBattle m then "Duel" else "World"), cmInBattle m && cmMobileTab m /= "world", 0),
          ("log", if zh then "纪事" else "Log", False, cmUnreadLogs m),
          ("arts", if zh then "武学" else "Arts", isJust (psBusy (cmStats m)), 0),
          ("character", if zh then "角色" else "Hero", liveInj > 0, 0),
          ("quests", if zh then "任务" else "Quests", False, activeQ)
        ]

      bg =
        cmdRect 0 y0 w 54 0 "#f5efe1" "" 0 0.98
          <> cmdLine 0 y0 w y0 1 "#c6baa3" 0.95 False
      swallow = CanvasHitbox 0 y0 w 54 HitSwallow "default"

      renderTab (idx, (tid, lbl, hasDot, badge)) =
        let tx = fromIntegral idx * tw
            cx = tx + tw * 0.5
            act = cmMobileTab m == tid
            col = if act then "#a32c22" else "#5c5346"
            topMark = if act then cmdRect (tx + 12) y0 (tw - 24) 2.5 0 "#a32c22" "" 0 1 else mempty
            -- Minimalist geometric ink icons drawn directly on Canvas
            iconB = case tid of
              "world" ->
                cmdCirc cx (y0 + 19) 7.5 "" col 1.4 0.95
                  <> cmdLine (cx - 3.5) (y0 + 22.5) (cx + 3.5) (y0 + 15.5) 1.4 col 0.95 False
              "log" ->
                cmdRect (cx - 8) (y0 + 12) 16 12 2 "" col 1.3 0.95
                  <> cmdLine (cx - 4) (y0 + 16.5) (cx + 4) (y0 + 16.5) 1.2 col 0.9 False
                  <> cmdLine (cx - 4) (y0 + 20) (cx + 2) (y0 + 20) 1.2 col 0.9 False
              "arts" ->
                cmdRect (cx - 8) (y0 + 12) 7.5 13 1 "" col 1.3 0.95
                  <> cmdRect (cx + 0.5) (y0 + 12) 7.5 13 1 "" col 1.3 0.95
              "character" ->
                cmdCirc cx (y0 + 15.5) 3.6 "" col 1.3 0.95
                  <> cmdLine (cx - 6) (y0 + 25) (cx + 6) (y0 + 25) 1.4 col 0.95 False
              _ ->
                cmdRect (cx - 6.5) (y0 + 11.5) 13 14 1.5 "" col 1.3 0.95
                  <> cmdLine (cx - 3.5) (y0 + 16) (cx + 3.5) (y0 + 16) 1.2 col 0.9 False
                  <> cmdLine (cx - 3.5) (y0 + 20) (cx + 2) (y0 + 20) 1.2 col 0.9 False
            dotB =
              if badge > 0
                then
                  cmdRect (cx + 8) (y0 + 6) 16 14 7 "#a32c22" "" 0 0.95
                    <> cmdTx (cx + 16) (y0 + 16.5) 9.5 "700" "center" "#f7f1e3" 1 (if badge > 9 then "9+" else T.pack (show badge))
                else
                  if hasDot
                    then cmdCirc (cx + 11) (y0 + 11) 3.2 (if tid == "arts" then "#2b594b" else "#a32c22") "" 0 1
                    else mempty
            lblB = cmdTx cx (y0 + 44) 10.5 (if act then "700" else "500") "center" col 1 lbl
         in (topMark <> iconB <> dotB <> lblB, CanvasHitbox tx y0 tw 54 (HitUi "mobile_tab" tid "") "pointer")

      (tBs, tHs) = unzip (map renderTab (zip [0 :: Int ..] tabs))
   in (bg <> mconcat tBs, swallow : tHs)

-- Room Info Floating Card & Map Controls

drawRoomCard :: ClientModel -> Bool -> (B.Builder, [CanvasHitbox])
drawRoomCard m isMob =
  let w = cmWidth m
      x0 = if isMob then 10.0 else 16.0
      y0 = if isMob then 64.0 else 64.0
      cw = if isMob then w - 20.0 else min 420.0 (w - 32.0)
      pad = if isMob then 10.0 else 13.0
      mName = currentMapName m
      descLines = take (if isMob then 3 else 4) (wrapText (cw - pad * 2) 12.0 (cmRoomDesc m))
      descH = fromIntegral (length descLines) * 17.5

      -- Layout NPC chips in rows
      chipStartY = y0 + 34.0 + descH + (if null (cmRoomChars m) then 0 else 6)
      layoutChips [] _ curY _ accB accH = (accB, accH, curY)
      layoutChips (npc : rest) curX curY rowH accB accH =
        let isHostile = "attack" `elem` rcActions npc
            bw = min (cw - pad * 2) (textWidth 12 (rcName npc) + (if isHostile then 28 else 22))
            (nx, ny) = if curX + bw > x0 + cw - pad && curX > x0 + pad then (x0 + pad, curY + rowH + 6) else (curX, curY)
            sel = cmSelectedNpc m == Just (rcId npc)
            tone = if sel then ToneActive else if isHostile then ToneDanger else ToneJade
            (b, h1) = drawBtn m nx ny bw 26 (rcName npc) 11.5 tone (cmStoryActive m) (HitUi "select_npc" (rcId npc) "")
         in layoutChips rest (nx + bw + 6) ny 26 (accB <> b) (accH <> h1)

      (npcB, npcH, endChipY) = layoutChips (cmRoomChars m) (x0 + pad) chipStartY 26 mempty []
      cardH = (if null (cmRoomChars m) then y0 + 32.0 + descH + 10.0 else endChipY + 34.0) - y0

      bg =
        cmdRect x0 y0 cw cardH 3 "#f6f0e2" "#b8aa91" 1.1 0.94
          <> cmdRect x0 y0 3.5 cardH 0 "#946623" "" 0 0.95
          <> cmdSerif (x0 + pad + 2) (y0 + 22) (if isMob then 15 else 16) "700" "left" "#1e1a16" 1 (cmRoomName m)
      mapChip =
        if T.null mName
          then mempty
          else
            let mw = textWidth 11 mName + 16
             in cmdRect (x0 + cw - pad - mw) (y0 + 7) mw 20 2 "#ebe2ce" "#b8aa91" 0.9 1
                  <> cmdTx (x0 + cw - pad - mw * 0.5) (y0 + 20.5) 10.5 "600" "center" "#5c5346" 1 mName
      descB = mconcat [cmdTx (x0 + pad + 2) (y0 + 42 + fromIntegral i * 17.5) 12 "400" "left" "#4a4136" 1 ln | (i, ln) <- zip [0 :: Int ..] descLines]
      swallow = CanvasHitbox x0 y0 cw cardH HitSwallow "default"
   in (bg <> mapChip <> descB <> npcB, swallow : npcH)

drawMapControls :: ClientModel -> Bool -> (B.Builder, [CanvasHitbox])
drawMapControls m isMob =
  let w = cmWidth m
      zh = cmLocale m == Zh
      rightEdge = if not isMob && not (T.null (cmDesktopDrawer m)) then w - 394 else w - 14
      y0 = if isMob then 176.0 else 66.0
      (bIn, hIn) = drawBtn m (rightEdge - 30) y0 30 28 "+" 15 ToneDefault False (HitUi "zoom_in" "" "")
      (bOut, hOut) = drawBtn m (rightEdge - 30) (y0 + 34) 30 28 "−" 15 ToneDefault False (HitUi "zoom_out" "" "")
      (bCen, hCen) =
        if isCameraPanned m
          then drawBtn m (rightEdge - 56) (y0 + 70) 56 26 (if zh then "归位" else "Center") 11 TonePrimary False (HitUi "reset_cam" "" "")
          else (mempty, [])
   in (bIn <> bOut <> bCen, hIn <> hOut <> hCen)

-- NPC Interaction Modal (with Dim Backdrop & Scrollable Teach/Shop List)

drawNpcModal :: ClientModel -> Bool -> (B.Builder, [CanvasHitbox], [ScrollZone], Double)
drawNpcModal m isMob = case cmSelectedNpc m >>= \cid -> find (\c -> rcId c == cid) (cmRoomChars m) of
  Nothing -> (mempty, [], [], 0)
  Just npc ->
    let w = cmWidth m
        h = cmHeight m
        zh = cmLocale m == Zh
        idle = not (cmStoryActive m) && isNothing (psBusy (cmStats m))
        mw = min 420.0 (w - 28.0)
        maxH = h - (if isMob then 140.0 else 130.0)
        mx = (w - mw) * 0.5
        pad = 16.0
        innerW = mw - pad * 2

        backdrop = cmdRect 0 0 w h 0 "#1e1a16" "" 0 0.32
        backHit = CanvasHitbox 0 0 w h (HitUi "select_npc" "" "") "default"

        descLines = if T.null (rcDesc npc) then [] else wrapText innerW 12.5 (rcDesc npc)
        canTalk = "talk" `elem` rcActions npc || "dialogue" `elem` rcActions npc || null (rcActions npc)
        canAtk = "attack" `elem` rcActions npc

        -- Measure total body height
        bodyH =
          fromIntegral (length descLines) * 18
            + 44
            + (if null (rcTeaches npc) then 0 else 28 + fromIntegral (length (rcTeaches npc)) * 34)
            + (if null (rcShop npc) then 0 else 28 + fromIntegral (length (rcShop npc)) * 34)
        mh = min maxH (max 150.0 (56.0 + bodyH + 14.0))
        my = max 62.0 ((h - mh) * 0.45)
        viewH = mh - 56.0
        maxS = max 0.0 (bodyH - viewH)
        scrollY = max 0.0 (min maxS (cmNpcScroll m))

        frame =
          cmdRect mx my mw mh 4 "#f6f0e2" "#946623" 1.4 0.99
            <> cmdSerif (mx + pad) (my + 30) 17 "700" "left" "#1e1a16" 1 (rcName npc)
            <> cmdLine (mx + pad) (my + 44) (mx + mw - pad) (my + 44) 1 "#d6cab2" 1 False
        (bClose, hClose) = drawBtn m (mx + mw - 40) (my + 10) 28 28 "×" 15 ToneGhost False (HitUi "select_npc" "" "")

        yStart = my + 54.0 - scrollY
        x0 = mx + pad
        descB = mconcat [cmdTx x0 (yStart + 14 + fromIntegral i * 18) 12.5 "400" "left" "#4a4136" 1 ln | (i, ln) <- zip [0 :: Int ..] descLines]
        yAct = yStart + fromIntegral (length descLines) * 18 + 6
        (bTalk, hTalk) = if canTalk then drawBtn m x0 yAct 88 30 (if zh then "交谈" else "Talk") 12.5 TonePrimary (cmStoryActive m) (HitUi "talk" (rcId npc) "") else (mempty, [])
        (bAtk, hAtk) = if canAtk then drawBtn m (x0 + (if canTalk then 96 else 0)) yAct 96 30 (if zh then "动手攻击" else "Attack") 12.5 ToneDanger (cmStoryActive m) (HitUi "attack" (rcId npc) "") else (mempty, [])

        yTeach0 = yAct + 42
        (teachB, teachH, yShop0) =
          if null (rcTeaches npc)
            then (mempty, [], yTeach0)
            else
              let hdr = cmdTx x0 (yTeach0 + 12) 11.5 "700" "left" "#8b7f6e" 1 (if zh then "可传武学" else "Teaches")
                  rows =
                    [ let ry = yTeach0 + 22 + fromIntegral i * 34
                          lbl = taName t <> " (≤" <> T.pack (show (taMaxLevel t)) <> ")"
                          tx = cmdTx x0 (ry + 18) 12.5 "600" "left" "#1e1a16" 1 (truncateText (innerW - 126) 12.5 lbl)
                          (b1, h1) = drawBtn m (x0 + innerW - 122) ry 56 26 (if zh then "学艺" else "Learn") 11.5 ToneDefault (not idle) (HitUi "learn" (rcId npc <> ":" <> taId t) "1")
                          (b10, h10) = drawBtn m (x0 + innerW - 60) ry 60 26 (if zh then "学十次" else "×10") 11.5 ToneDefault (not idle) (HitUi "learn" (rcId npc <> ":" <> taId t) "10")
                       in (tx <> b1 <> b10, h1 <> h10)
                      | (i, t) <- zip [0 :: Int ..] (rcTeaches npc)
                    ]
               in (hdr <> mconcat (map fst rows), concatMap snd rows, yTeach0 + 28 + fromIntegral (length (rcTeaches npc)) * 34)

        (shopB, shopH) =
          if null (rcShop npc)
            then (mempty, [])
            else
              let hdr = cmdTx x0 (yShop0 + 12) 11.5 "700" "left" "#8b7f6e" 1 (if zh then "行商货架" else "Shop")
                  rows =
                    [ let ry = yShop0 + 22 + fromIntegral i * 34
                          canAfford = cmMoney m >= siPrice s && not (cmStoryActive m) && not (cmInBattle m)
                          lbl = siName s <> " (" <> T.pack (show (siPrice s)) <> (if zh then "碎银)" else "s)")
                          tx = cmdTx x0 (ry + 18) 12.5 "600" "left" "#1e1a16" 1 (truncateText (innerW - 72) 12.5 lbl)
                          (bBuy, hBuy) = drawBtn m (x0 + innerW - 64) ry 64 26 (if zh then "购买" else "Buy") 11.5 ToneJade (not canAfford) (HitUi "buy" (rcId npc <> ":" <> siId s) "")
                       in (tx <> bBuy, hBuy)
                      | (i, s) <- zip [0 :: Int ..] (rcShop npc)
                    ]
               in (hdr <> mconcat (map fst rows), concatMap snd rows)

        clipY = my + 48
        clipH = mh - 54
        bodyAll = cmdClip (mx + 2) clipY (mw - 4) clipH <> descB <> bTalk <> bAtk <> teachB <> shopB <> cmdUnclip
        sb = drawScrollbar (mx + mw - 7) clipY clipH scrollY maxS viewH
        allInnerHits = filter (\hb -> chY hb + chH hb >= clipY && chY hb <= clipY + clipH) (hTalk <> hAtk <> teachH <> shopH)
        swallow = CanvasHitbox mx my mw mh HitSwallow "default"
     in (backdrop <> frame <> bClose <> bodyAll <> sb, [backHit, swallow] <> hClose <> allInnerHits, [ScrollZone mx clipY mw clipH ScrollNpc], maxS)

-- Battle Top HUD (Dual Combatants: HP + Ghost Trail, Qi, Live Predicted AP, Live Buff/Debuff Chips, Hit-Flash)

drawBattleTopBar :: ClientModel -> Bool -> Double -> (B.Builder, [CanvasHitbox])
drawBattleTopBar m isMob y0 =
  let w = cmWidth m
      zh = cmLocale m == Zh
      (pHp, pMaxHp, pQi, pMaxQi) = presentedVitals m
      (eName, eHp, eMaxHp, eQi, eMaxQi) = enemyVitals m
      pEffs = liveEffectsOf m True
      eEffs = liveEffectsOf m False
      totalW = min 760.0 (w - (if isMob then 16.0 else 32.0))
      x0 = (w - totalW) * 0.5
      midW = if isMob then 6.0 else 84.0
      cardW = (totalW - midW - 12.0) * 0.5

      drawCard cx name hp mhp hpTrail qi mqi apVal effs hitFlash =
        let hasEff = not (null effs)
            ch = if hasEff then 106.0 else 86.0
            bd = if hitFlash then "#a32c22" else "#b8aa91"
            bg = if hitFlash then "#faece8" else "#f6f0e2"
            box =
              cmdRect cx y0 cardW ch 3 bg bd (if hitFlash then 2.0 else 1.1) 0.96
                <> cmdSerif (cx + 10) (y0 + 19) 13.5 "700" "left" "#1e1a16" 1 (truncateText (cardW - 20) 13.5 name)
                <> drawMeter (cx + 10) (y0 + 26) (cardW - 20) 14 (fromIntegral hp / fromIntegral (max 1 mhp)) (Just hpTrail) "#a32c22" "#d48d72" (T.pack (show hp) <> "/" <> T.pack (show mhp))
                <> drawMeter (cx + 10) (y0 + 44) (cardW - 20) 13 (fromIntegral qi / fromIntegral (max 1 mqi)) Nothing "#2b594b" "" (T.pack (show qi) <> "/" <> T.pack (show mqi))
                <> drawMeter (cx + 10) (y0 + 61) (cardW - 20) 12 (apVal / 100.0) Nothing "#946623" "" ("AP " <> T.pack (show (round apVal :: Int)))
            effB =
              if not hasEff
                then mempty
                else
                  let renderEff (accX, accB) (ef, remS) =
                        let lbl = efName ef <> " " <> T.pack (show (ceiling remS :: Int)) <> "s"
                            ew = textWidth 10 lbl + 10
                            isBad = efType ef == "dot" || efType ef == "debuff"
                            eb =
                              if accX + ew > cx + cardW - 8
                                then mempty
                                else
                                  cmdRect accX (y0 + 78) ew 18 2 (if isBad then "#f7e3e0" else "#e5f0eb") (if isBad then "#a32c22" else "#2b594b") 0.8 1
                                    <> cmdTx (accX + ew * 0.5) (y0 + 90.5) 10 "600" "center" (if isBad then "#8f1f16" else "#245243") 1 lbl
                         in (accX + ew + 4, accB <> eb)
                   in snd (foldl' renderEff (cx + 10, mempty) (take 4 effs))
         in (box <> effB, CanvasHitbox cx y0 cardW ch HitSwallow "default")

      (pCard, pSw) = drawCard x0 (if T.null (cmUsername m) then "行者" else cmUsername m) pHp pMaxHp (cmPlayerHpTrail m) pQi pMaxQi (cmPlayerApAnim m) pEffs (cmPlayerHitFlashMs m > 0)
      (eCard, eSw) = drawCard (x0 + cardW + midW + 12) eName eHp eMaxHp (cmEnemyHpTrail m) eQi eMaxQi (cmEnemyApAnim m) eEffs (cmEnemyHitFlashMs m > 0)
      sndLbl = if zh then (if cmSoundOn m then "音效：开" else "音效：关") else (if cmSoundOn m then "SFX On" else "SFX Off")
      (bSnd, hSnd) =
        if isMob
          then drawBtn m (w - 78) (y0 + 90) 68 24 sndLbl 10.5 ToneGhost False (HitUi "toggle_sound" "" "")
          else drawBtn m (x0 + cardW + 10) (y0 + 28) (midW - 8) 28 sndLbl 11 ToneGhost False (HitUi "toggle_sound" "" "")
   in (pCard <> eCard <> bSnd, [pSw, eSw] <> hSnd)

-- Battle Active Skill Bar (Cooldown Ink Curtain + Queued Cinnabar Seal + Keycaps + Reasons)

drawBattleSkills :: ClientModel -> Bool -> Double -> (B.Builder, [CanvasHitbox], Double)
drawBattleSkills m isMob bottomAnchorY =
  let evals = evalSkillState m
   in if null evals
        then (mempty, [], bottomAnchorY)
        else
          let w = cmWidth m
              zh = cmLocale m == Zh
              panelW = min 760.0 (w - (if isMob then 16.0 else 32.0))
              cols = if isMob then min 3 (length evals) else min 6 (length evals)
              gap = 8.0
              btnW = min 134.0 ((panelW - fromIntegral (cols - 1) * gap) / fromIntegral (max 1 cols))
              btnH = 48.0
              rows = (length evals + cols - 1) `div` max 1 cols
              totalH = fromIntegral rows * btnH + fromIntegral (max 0 (rows - 1)) * 6.0
              startY = bottomAnchorY - totalH - 6.0

              renderSkill (idx, ev) =
                let sk = seSkill ev
                    r = idx `div` cols
                    c = idx `mod` cols
                    rowCount = min cols (length evals - r * cols)
                    rowW = fromIntegral rowCount * btnW + fromIntegral (max 0 (rowCount - 1)) * gap
                    bx = (w - rowW) * 0.5 + fromIntegral c * (btnW + gap)
                    by = startY + fromIntegral r * (btnH + 6.0)
                    tgt = HitUi "perform" (asId sk) ""
                    hov = seReady ev && cmHovered m == Just tgt
                    bg = if seQueued ev then "#f2e5cb" else if hov then "#ede3cd" else "#f6f0e2"
                    bd = if seQueued ev then "#946623" else if seUltimate ev then "#a32c22" else if seReady ev then "#2b594b" else "#c5b9a0"
                    al = if seReady ev || seQueued ev then 0.98 else 0.62
                    cdPct = if seCdRem ev > 0.05 then min 1.0 (seCdRem ev / seCdTotal ev) else 0.0
                    curtain = if cdPct > 0.005 then cmdRect bx by (btnW * cdPct) btnH 3 "#946623" "" 0 0.20 else mempty
                    badgeB =
                      if seQueued ev
                        then
                          cmdRect (bx + 4) (by + 4) 16 16 2 "#a32c22" "" 0 0.95
                            <> cmdTx (bx + 12) (by + 15.5) 10 "700" "center" "#f7f1e3" 1 (if zh then "蓄" else "Q")
                        else
                          if idx < 6 && not isMob
                            then cmdTx (bx + 9) (by + 15) 10 "700" "center" "#8b7f6e" 0.9 (T.pack (show (idx + 1)))
                            else mempty
                    b =
                      cmdRect bx by btnW btnH 3 bg bd (if seQueued ev || seReady ev then 1.5 else 1.0) al
                        <> curtain
                        <> badgeB
                        <> cmdTx (bx + btnW * 0.5) (by + 21) 12.5 "700" "center" "#1e1a16" al (truncateText (btnW - 14) 12.5 (asName sk))
                        <> cmdTx (bx + btnW * 0.5) (by + 38) 10.5 "500" "center" (if seQueued ev then "#946623" else if seCdRem ev > 0.05 then "#a32c22" else "#5c5346") al (truncateText (btnW - 10) 10.5 (seReason ev))
                    hb = if seReady ev then [CanvasHitbox bx by btnW btnH tgt "pointer"] else [CanvasHitbox bx by btnW btnH HitSwallow "not-allowed"]
                 in (b, hb)

              (bs, hs) = unzip (map renderSkill (zip [0 :: Int ..] evals))
           in (mconcat bs, concat hs, startY)

-- Message Log Dock (Scrollable, Auto-Wrapped CJK, Auto-Stick Bottom + Canvas Say Input)

drawMessageDock :: ClientModel -> Bool -> Double -> Double -> Bool -> (B.Builder, [CanvasHitbox], [ScrollZone], Double)
drawMessageDock m isMob dockY dockH compact =
  let w = cmWidth m
      zh = cmLocale m == Zh
      dockW = if isMob then w - 20.0 else min 760.0 (w - 32.0)
      dockX = (w - dockW) * 0.5
      inpH = if compact then 0.0 else 38.0
      logViewH = max 36.0 (dockH - inpH - 12.0)
      logX = dockX + 12.0
      logY = dockY + 8.0
      logW = dockW - 26.0

      -- Wrap all log lines
      fontSz = 12.5
      lineH = 18.0
      wrapped =
        [ (llKind l, ln)
          | l <- cmLogs m,
            ln <- wrapText logW fontSz (llText l)
        ]
      totalH = fromIntegral (length wrapped) * lineH + 6.0
      maxS = max 0.0 (totalH - logViewH)
      scrollY = if cmLogStickBottom m then maxS else max 0.0 (min maxS (cmLogScroll m))

      lineColor k = case k of
        "move" -> "#946623"
        "combat" -> "#a32c22"
        "dialogue" -> "#2b594b"
        "say" -> "#294e6d"
        "reward" -> "#8f5f16"
        "error" -> "#a32c22"
        "system" -> "#5c5346"
        _ -> "#1e1a16"

      linesB =
        mconcat
          [ let ly = logY + 13.0 + fromIntegral i * lineH - scrollY
             in if ly < logY - lineH || ly > logY + logViewH + lineH
                  then mempty
                  else cmdTx logX ly fontSz (if k == "move" || k == "reward" then "600" else "400") "left" (lineColor k) 1 txt
            | (i, (k, txt)) <- zip [0 :: Int ..] wrapped
          ]

      frame = cmdRect dockX dockY dockW dockH 3 "#f6f0e2" "#b8aa91" 1.1 0.95
      clippedLogs = cmdClip (dockX + 4) logY (dockW - 12) logViewH <> linesB <> cmdUnclip
      sb = drawScrollbar (dockX + dockW - 7) logY logViewH scrollY maxS logViewH

      -- "Jump to latest" pill if scrolled up
      (bJump, hJump) =
        if not (cmLogStickBottom m) && maxS > 10.0
          then drawBtn m (dockX + dockW - 78) (logY + logViewH - 26) 64 22 (if zh then "↓ 最新" else "↓ Latest") 10.5 TonePrimary False (HitUi "scroll_log_bottom" "" "")
          else (mempty, [])

      -- Bottom Say Input Row (only attach native IME overlay when unobstructed by modal/drawer)
      canAttachIme = isNothing (cmSelectedNpc m) && (isMob || T.null (cmDesktopDrawer m)) && not (cmStoryActive m)
      (inpB, inpHits) =
        if compact
          then (mempty, [])
          else
            let iy = dockY + dockH - inpH
                ix = dockX + 8
                iw = dockW - 128
                focused = cmFocusedInput m == Just "say"
                draft = cmSayDraft m
                blink = focused && ((floor (cmClockMs m / 520.0) :: Int) `mod` 2 == 0)
                disp = if T.null draft then (if zh then "输入发言，回车发送…" else "Say something…") else draft
                caretX = ix + 8 + (if T.null draft then 0 else textWidth 12 draft)
                sep = cmdLine dockX iy (dockX + dockW) iy 1 "#d6cab2" 1 False
                box =
                  cmdRect ix (iy + 6) iw 26 2 "#fcf9f2" (if focused then "#946623" else "#c5b9a0") (if focused then 1.5 else 1.0) 1
                    <> cmdTx (ix + 8) (iy + 23) 12 "400" "left" (if T.null draft then "#8b7f6e" else "#1e1a16") 1 (truncateText (iw - 14) 12 disp)
                    <> (if blink then cmdLine (min (ix + iw - 6) caretX) (iy + 10) (min (ix + iw - 6) caretX) (iy + 28) 1.3 "#1e1a16" 0.9 False else mempty)
                    <> (if canAttachIme then cmdInput "say" ix (iy + 6) iw 26 draft else mempty)
                iHit = CanvasHitbox ix (iy + 6) iw 26 (HitFocusInput "say") "text"
                (bSend, hSend) = drawBtn m (ix + iw + 6) (iy + 6) 52 26 (if zh then "发送" else "Send") 11.5 TonePrimary (cmStoryActive m) (HitUi "send_say_draft" "" "")
                (bClr, hClr) = drawBtn m (ix + iw + 62) (iy + 6) 50 26 (if zh then "清屏" else "Clear") 11.5 ToneGhost False (HitUi "clear_logs" "" "")
             in (sep <> box <> bSend <> bClr, [iHit] <> hSend <> hClr)

      swallow = CanvasHitbox dockX dockY dockW dockH HitSwallow "default"
      sZone = ScrollZone dockX logY dockW logViewH ScrollLog
   in (frame <> clippedLogs <> sb <> bJump <> inpB, [swallow] <> hJump <> inpHits, [sZone], maxS)

-- Side Drawers (Character / Inventory, Martial Arts, Quests)

drawSideDrawer :: ClientModel -> Bool -> Text -> (B.Builder, [CanvasHitbox], [ScrollZone], Double)
drawSideDrawer m isMob drawerKind =
  let w = cmWidth m
      h = cmHeight m
      zh = cmLocale m == Zh
      dx = if isMob then 0.0 else w - 380.0
      dy = if isMob then 56.0 else 52.0
      dw = if isMob then w else 380.0
      dh = if isMob then h - 110.0 else h - 52.0
      pad = 14.0
      innerW = dw - pad * 2

      (backB, backH) =
        if isMob
          then (mempty, [])
          else (cmdRect 0 52 (w - 380) (h - 52) 0 "#1e1a16" "" 0 0.22, [CanvasHitbox 0 52 (w - 380) (h - 52) (HitUi "desktop_drawer" "" "") "default"])

      frame =
        cmdRect dx dy dw dh 0 "#f6f0e2" "" 0 0.99
          <> (if isMob then mempty else cmdLine dx dy dx (dy + dh) 1.2 "#b8aa91" 1 False)
          <> cmdLine (dx + pad) (dy + 48) (dx + dw - pad) (dy + 48) 1 "#d6cab2" 1 False
      swallow = CanvasHitbox dx dy dw dh HitSwallow "default"

      -- Drawer header
      (hdrB, hdrH) = case drawerKind of
        "character" ->
          let (b1, h1) = drawBtn m (dx + pad) (dy + 10) 92 28 (if zh then "角色属性" else "Status") 12 (if cmCharSubTab m == "status" then ToneActive else ToneGhost) False (HitUi "char_subtab" "status" "")
              (b2, h2) = drawBtn m (dx + pad + 98) (dy + 10) 108 28 ((if zh then "行囊器物 " else "Bag ") <> "(" <> T.pack (show (length (cmInventory m))) <> ")") 12 (if cmCharSubTab m == "inventory" then ToneActive else ToneGhost) False (HitUi "char_subtab" "inventory" "")
              (bX, hX) = if isMob then (mempty, []) else drawBtn m (dx + dw - 42) (dy + 10) 28 28 "×" 15 ToneGhost False (HitUi "desktop_drawer" "" "")
           in (b1 <> b2 <> bX, h1 <> h2 <> hX)
        "arts" ->
          let t = cmdSerif (dx + pad) (dy + 30) 16 "700" "left" "#1e1a16" 1 ((if zh then "武学修为" else "Martial Arts") <> " (" <> T.pack (show (length (cmArts m))) <> ")")
              (bX, hX) = if isMob then (mempty, []) else drawBtn m (dx + dw - 42) (dy + 10) 28 28 "×" 15 ToneGhost False (HitUi "desktop_drawer" "" "")
           in (t <> bX, hX)
        _ ->
          let t = cmdSerif (dx + pad) (dy + 30) 16 "700" "left" "#1e1a16" 1 ((if zh then "江湖轶闻" else "Quests") <> " (" <> T.pack (show (length (cmQuests m))) <> ")")
              (bX, hX) = if isMob then (mempty, []) else drawBtn m (dx + dw - 42) (dy + 10) 28 28 "×" 15 ToneGhost False (HitUi "desktop_drawer" "" "")
           in (t <> bX, hX)

      clipY = dy + 54.0
      clipH = max 60.0 (dh - 60.0)
      scrollY0 = cmDrawerScroll m
      buildBody sy = case drawerKind of
        "character" -> buildCharDrawerBody m zh (dx + pad) (clipY + 4 - sy) innerW
        "arts" -> buildArtsDrawerBody m zh (dx + pad) (clipY + 4 - sy) innerW
        _ -> buildQuestsDrawerBody m zh (dx + pad) (clipY + 4 - sy) innerW

      (_, _, totalH) = buildBody 0
      maxS = max 0.0 (totalH - clipH + 12.0)
      scrollY = max 0.0 (min maxS scrollY0)
      (bodyB, bodyHits, _) = buildBody scrollY
      clipped = cmdClip (dx + 2) clipY (dw - 4) clipH <> bodyB <> cmdUnclip
      sb = drawScrollbar (dx + dw - 7) clipY clipH scrollY maxS clipH
      visHits = filter (\hb -> chY hb + chH hb >= clipY && chY hb <= clipY + clipH) bodyHits
   in (backB <> frame <> hdrB <> clipped <> sb, backH <> [swallow] <> hdrH <> visHits, [ScrollZone dx clipY dw clipH ScrollDrawer], maxS)

buildCharDrawerBody :: ClientModel -> Bool -> Double -> Double -> Double -> (B.Builder, [CanvasHitbox], Double)
buildCharDrawerBody m zh x0 y0 w =
  let st = cmStats m
      idle = cmConnected m && not (cmInBattle m) && not (cmStoryActive m) && isNothing (psBusy st)
   in if cmCharSubTab m == "inventory"
        then
          let moneyCard =
                cmdRect x0 y0 w 36 3 "#efe7d4" "#c5b9a0" 1 1
                  <> cmdTx (x0 + 12) (y0 + 23) 13 "600" "left" "#5c5346" 1 (if zh then "随身碎银" else "Silver")
                  <> cmdTx (x0 + w - 12) (y0 + 23) 14 "700" "right" "#946623" 1 (T.pack (show (cmMoney m)))
              renderItem (ay, bs, hs) it =
                let ih = 46.0
                    lbl = iiName it <> " ×" <> T.pack (show (iiAmount it)) <> (if iiEquipped it then (if zh then " · 已佩带" else " · Eq") else "")
                    card =
                      cmdRect x0 ay w ih 3 "#faf5e9" (if iiEquipped it then "#946623" else "#c8bca4") 1 1
                        <> cmdTx (x0 + 10) (ay + 27) 12.5 "600" "left" "#1e1a16" 1 (truncateText (w - 134) 12.5 lbl)
                    useLbl = if isJust (iiEquipSlot it) then (if iiEquipped it then (if zh then "卸下" else "Unequip") else (if zh then "佩带" else "Equip")) else (if zh then "使用" else "Use")
                    (bUse, hUse) = if iiUsable it then drawBtn m (x0 + w - (if iiStudyable it then 124 else 62)) (ay + 10) 54 26 useLbl 11.5 ToneDefault (cmInBattle m || cmStoryActive m) (HitUi "use" (iiId it) "") else (mempty, [])
                    (bStu, hStu) = if iiStudyable it then drawBtn m (x0 + w - 62) (ay + 10) 54 26 (if zh then "研读" else "Study") 11.5 ToneJade (not idle) (HitUi "study" (iiId it) "") else (mempty, [])
                 in (ay + ih + 8, bs <> card <> bUse <> bStu, hs <> hUse <> hStu)
              (endY, itemsB, itemsH) =
                if null (cmInventory m)
                  then (y0 + 76, cmdTx x0 (y0 + 62) 12.5 "400" "left" "#8b7f6e" 1 (if zh then "行囊空空如也。" else "Inventory is empty."), [])
                  else foldl' renderItem (y0 + 44, mempty, []) (cmInventory m)
           in (moneyCard <> itemsB, itemsH, endY - y0)
        else
          let (presHp, presMaxHp, presQi, presMaxQi) = presentedVitals m
              ageS = max 0.0 ((cmClockMs m - cmStatsSyncedAtMs m) / 1000.0)
              liveInj = max 0 (psInjuredSeconds st - floor ageS)
              pEffs = liveEffectsOf m True
              heroCard =
                cmdRect x0 y0 w 84 3 "#efe7d4" "#c5b9a0" 1 1
                  <> cmdImg (portraitScoreFile (psAppearance st)) (x0 + 10) (y0 + 10) 64 64 3
                  <> cmdSerif (x0 + 84) (y0 + 28) 15.5 "700" "left" "#1e1a16" 1 (cmUsername m)
                  <> cmdTx (x0 + 84) (y0 + 47) 12 "400" "left" "#5c5346" 1 (tr (cmLocale m) ("gender." <> psGender st) <> " · " <> (if T.null (psAppearanceText st) then "容貌 " <> T.pack (show (psAppearance st)) else psAppearanceText st))
                  <> (if liveInj > 0 then cmdTx (x0 + 84) (y0 + 66) 11.5 "700" "left" "#a32c22" 1 ("重伤未愈 " <> T.pack (show liveInj) <> "s") else if psCombatInsight st > 0 then cmdTx (x0 + 84) (y0 + 66) 11.5 "600" "left" "#2b594b" 1 ("实战印证 " <> T.pack (show (psCombatInsight st)) <> " 层") else mempty)

              yM = y0 + 94
              mCard =
                cmdRect x0 yM w 146 3 "#faf5e9" "#c8bca4" 1 1
                  <> cmdTx (x0 + 10) (yM + 18) 11.5 "600" "left" "#5c5346" 1 (if zh then "气血" else "HP")
                  <> drawMeter (x0 + 10) (yM + 24) (w - 20) 13 (fromIntegral presHp / fromIntegral (max 1 presMaxHp)) Nothing "#a32c22" "" (T.pack (show presHp) <> "/" <> T.pack (show presMaxHp))
                  <> cmdTx (x0 + 10) (yM + 52) 11.5 "600" "left" "#5c5346" 1 (if zh then "内力" else "Qi")
                  <> drawMeter (x0 + 10) (yM + 58) (w - 20) 13 (fromIntegral presQi / fromIntegral (max 1 presMaxQi)) Nothing "#2b594b" "" (T.pack (show presQi) <> "/" <> T.pack (show presMaxQi))
                  <> cmdTx (x0 + 10) (yM + 86) 11.5 "600" "left" "#5c5346" 1 (if zh then "精神" else "Spirit")
                  <> drawMeter (x0 + 10) (yM + 92) (w - 20) 13 (fromIntegral (psJing st) / fromIntegral (max 1 (psMaxJing st))) Nothing "#946623" "" (T.pack (show (psJing st)) <> "/" <> T.pack (show (psMaxJing st)))
              (bMed, hMed) = drawBtn m (x0 + 10) (yM + 112) 124 26 (if zh then "打坐周天" else "Meditate") 11.5 ToneJade (not idle || psQi st < 20) (HitUi "meditate" "" "")
              (bRef, hRef) = drawBtn m (x0 + 142) (yM + 112) 86 26 (if zh then "刷新状态" else "Refresh") 11.5 ToneGhost False (HitUi "refresh" "" "")

              yG = yM + 156
              cw = (w - 14) / 3.0
              cells =
                [ (if zh then "碎银" else "Silver", cmMoney m),
                  (if zh then "潜能" else "Potential", psPotential st),
                  (if zh then "实战经验" else "Exp", psCombatExp st),
                  (if zh then "臂力" else "STR", psStrength st),
                  (if zh then "身法" else "AGI", psAgility st),
                  (if zh then "根骨" else "VIT", psVitality st)
                ]
              gridB =
                mconcat
                  [ let cx = x0 + fromIntegral (i `mod` 3) * (cw + 7)
                        cy = yG + fromIntegral (i `div` 3) * 52
                     in cmdRect cx cy cw 44 3 "#faf5e9" "#c8bca4" 1 1
                          <> cmdTx (cx + cw * 0.5) (cy + 17) 11 "500" "center" "#6e6354" 1 k
                          <> cmdTx (cx + cw * 0.5) (cy + 36) 14.5 "700" "center" "#1e1a16" 1 (T.pack (show v))
                    | (i, (k, v)) <- zip [0 :: Int ..] cells
                  ]
              yEff = yG + 110
              (effB, effH) =
                if null pEffs
                  then (mempty, 0)
                  else
                    let hdr = cmdTx x0 (yEff + 12) 11.5 "700" "left" "#6e6354" 1 (if zh then "当前状态" else "Effects")
                        tags =
                          mconcat
                            [ let tx = x0 + fromIntegral (i `mod` 3) * (cw + 7)
                                  ty = yEff + 20 + fromIntegral (i `div` 3) * 26
                                  isBad = efType ef == "dot" || efType ef == "debuff"
                               in cmdRect tx ty cw 22 2 (if isBad then "#f7e3e0" else "#e5f0eb") (if isBad then "#a32c22" else "#2b594b") 0.8 1
                                    <> cmdTx (tx + cw * 0.5) (ty + 15) 11 "600" "center" (if isBad then "#8f1f16" else "#245243") 1 (efName ef <> " " <> T.pack (show (ceiling remS :: Int)) <> "s")
                              | (i, (ef, remS)) <- zip [0 :: Int ..] pEffs
                            ]
                     in (hdr <> tags, 24 + fromIntegral ((length pEffs + 2) `div` 3) * 26)
           in (heroCard <> mCard <> bMed <> bRef <> gridB <> effB, hMed <> hRef, (yEff + effH + 12) - y0)

buildArtsDrawerBody :: ClientModel -> Bool -> Double -> Double -> Double -> (B.Builder, [CanvasHitbox], Double)
buildArtsDrawerBody m zh x0 y0 w =
  let st = cmStats m
      idle = cmConnected m && not (cmInBattle m) && not (cmStoryActive m) && isNothing (psBusy st)
      (busyB, busyH, yList0) = case psBusy st of
        Nothing -> (mempty, [], y0)
        Just bi ->
          let ageS = max 0.0 ((cmClockMs m - cmStatsSyncedAtMs m) / 1000.0)
              remS = max 0.0 (biSeconds bi - ageS)
              stepS = max 0.2 (biStepSeconds bi)
              prog = max 0.04 (min 1.0 ((stepS - remS) / stepS))
              tot = biCompleted bi + biRemaining bi
              tName = fromMaybe (biTarget bi) (fmap aiName (find (\a -> aiId a == biTarget bi) (cmArts m)))
              lbl = tr (cmLocale m) ("training.action." <> biAction bi) <> " " <> tName <> " " <> T.pack (show (biCompleted bi)) <> "/" <> T.pack (show tot)
              card =
                cmdRect x0 y0 w 60 3 "#f2e7cf" "#946623" 1.4 1
                  <> cmdTx (x0 + 10) (y0 + 21) 12.5 "700" "left" "#5e3d0e" 1 (truncateText (w - 78) 12.5 (lbl <> " · " <> T.pack (show (fromIntegral (round (remS * 10) :: Int) / 10.0 :: Double)) <> "s"))
                  <> drawMeter (x0 + 10) (y0 + 36) (w - 20) 10 prog Nothing "#946623" "" ""
              (bHalt, hHalt) = drawBtn m (x0 + w - 62) (y0 + 8) 52 24 (if zh then "停下" else "Stop") 11.5 ToneDanger False (HitUi "halt" "" "")
           in (card <> bHalt, hHalt, y0 + 70)

      renderArt (ay, bs, hs) a =
        let loc = cmLocale m
            blkTxt = case aiBlocker a of
              Just "combat_exp" -> trParams loc "art.blocker.combat_exp" [("required", T.pack (show (aiNextCombatExp a)))]
              Just "foundation" -> tr loc "art.blocker.foundation"
              Just "max_level" -> tr loc "art.blocker.max_level"
              _ -> ""
            movesTxt = T.intercalate " / " (aiUnlockedMoves a <> aiUnlockedSkills a)
            canRes = not (aiIsFoundation a) && aiLevel a >= aiResearchFrom a && aiLevel a < aiMaxLevel a
            maxed = aiBlocker a == Just "max_level"
            hasProg = aiNextProgress a > 0
            hasBlk = not (T.null blkTxt)
            hasMvs = not (T.null movesTxt)
            hasBtns = not (aiIsFoundation a)
            ch =
              46.0
                + (if hasProg then 16 else 0)
                + (if hasBlk then 17 else 0)
                + (if hasMvs then 17 else 0)
                + (if hasBtns then 34 else 0)
            bd = if aiEnabled a then "#946623" else "#c8bca4"
            card =
              cmdRect x0 ay w ch 3 (if aiEnabled a then "#f3ead6" else "#faf5e9") bd (if aiEnabled a then 1.5 else 1.0) 1
                <> cmdTx (x0 + 10) (ay + 20) 13.5 "700" "left" "#1e1a16" 1 (aiName a)
                <> cmdTx (x0 + w - 10) (ay + 20) 11 "600" "right" "#6e6354" 1 (formatArtType loc (aiType a))
                <> cmdTx (x0 + 10) (ay + 37) 11.5 "400" "left" "#5c5346" 1
                     (artRankTitle loc (aiLevel a) <> " · " <> trParams loc "art.level" [("level", T.pack (show (aiLevel a))), ("max", T.pack (show (aiMaxLevel a)))])
            y1 = ay + 44
            progB = if hasProg then drawMeter (x0 + 10) y1 (w - 20) 7 (fromIntegral (aiProgress a) / fromIntegral (max 1 (aiNextProgress a))) Nothing "#2b594b" "" "" else mempty
            y2 = y1 + (if hasProg then 16 else 0)
            blkB = if hasBlk then cmdTx (x0 + 10) (y2 + 10) 11 "600" "left" "#a32c22" 1 (truncateText (w - 20) 11 blkTxt) else mempty
            y3 = y2 + (if hasBlk then 17 else 0)
            mvB = if hasMvs then cmdTx (x0 + 10) (y3 + 10) 11 "400" "left" "#6e6354" 1 (truncateText (w - 20) 11 movesTxt) else mempty
            y4 = y3 + (if hasMvs then 17 else 0)
            (btnB, btnH) =
              if not hasBtns
                then (mempty, [])
                else
                  let (bP1, hP1) = if not maxed then drawBtn m (x0 + 10) y4 54 25 (if zh then "练功" else "Train") 11.5 ToneDefault (not idle) (HitUi "practice" (aiId a) "1") else (mempty, [])
                      (bP10, hP10) = if not maxed then drawBtn m (x0 + 70) y4 60 25 (if zh then "练十次" else "×10") 11.5 ToneDefault (not idle) (HitUi "practice" (aiId a) "10") else (mempty, [])
                      nx = x0 + (if maxed then 10 else 136)
                      (bRes, hRes) = if canRes then drawBtn m nx y4 52 25 (if zh then "自研" else "Study") 11.5 ToneJade (not idle) (HitUi "research" (aiId a) "") else (mempty, [])
                      ex = nx + (if canRes then 58 else 0)
                      (bEn, hEn) =
                        if aiEnabled a
                          then (cmdTx (ex + 4) (y4 + 17) 11.5 "700" "left" "#946623" 1 (if zh then "✓ 已启用" else "✓ On"), [])
                          else drawBtn m ex y4 54 25 (if zh then "启用" else "Enable") 11.5 TonePrimary (cmInBattle m) (HitUi "enable" (aiType a) (aiId a))
                   in (bP1 <> bP10 <> bRes <> bEn, hP1 <> hP10 <> hRes <> hEn)
         in (ay + ch + 8, bs <> card <> progB <> blkB <> mvB <> btnB, hs <> btnH)

      (endY, artsB, artsH) =
        if null (cmArts m)
          then (yList0 + 36, cmdTx x0 (yList0 + 20) 12.5 "400" "left" "#8b7f6e" 1 (if zh then "尚未习得武学。" else "No martial arts learned."), [])
          else foldl' renderArt (yList0, mempty, []) (cmArts m)
   in (busyB <> artsB, busyH <> artsH, endY - y0)

buildQuestsDrawerBody :: ClientModel -> Bool -> Double -> Double -> Double -> (B.Builder, [CanvasHitbox], Double)
buildQuestsDrawerBody m zh x0 y0 w =
  if null (cmQuests m)
    then (cmdTx x0 (y0 + 20) 12.5 "400" "left" "#8b7f6e" 1 (if zh then "暂无江湖轶闻。" else "No quests yet."), [], 36)
    else
      let renderQ (ay, bs) q =
            let objLines = maybe [] (wrapText (w - 20) 12) (qiObjective q)
                rewTxt = T.intercalate "、" [rwName r <> " ×" <> T.pack (show (rwAmount r)) | r <- qiRewards q]
                ch = 34 + fromIntegral (length objLines) * 17 + (if T.null rewTxt then 6 else 22)
                card =
                  cmdRect x0 ay w ch 3 "#faf5e9" (if qiCompleted q then "#c8bca4" else "#946623") 1 1
                    <> cmdTx (x0 + 10) (ay + 21) 13 "700" "left" "#1e1a16" 1 (qiName q)
                    <> cmdTx (x0 + w - 10) (ay + 21) 11 "700" "right" (if qiCompleted q then "#2b594b" else "#946623") 1 (if qiCompleted q then (if zh then "已完成" else "Done") else (if zh then "进行中" else "Active"))
                    <> mconcat [cmdTx (x0 + 10) (ay + 39 + fromIntegral i * 17) 12 "400" "left" "#4a4136" 1 ln | (i, ln) <- zip [0 :: Int ..] objLines]
                    <> (if T.null rewTxt then mempty else cmdTx (x0 + 10) (ay + ch - 8) 11 "500" "left" "#8b7f6e" 1 (truncateText (w - 20) 11 ((if zh then "奖励：" else "Reward: ") <> rewTxt)))
             in (ay + ch + 8, bs <> card)
          (endY, qb) = foldl' renderQ (y0, mempty) (cmQuests m)
       in (qb, [], endY - y0)

-- Shared Vitals Helpers

presentedVitals :: ClientModel -> (Int, Int, Int, Int)
presentedVitals m =
  let st = cmStats m
      hp = case (cmInBattle m, cmPresentation m, cmBattleSnap m) of
        (True, Just pr, _) -> prPlayerHp pr
        (True, Nothing, Just bs) -> cbHp (bsPlayer bs)
        _ -> psHp st
      mhp = case (cmInBattle m, cmBattleSnap m) of
        (True, Just bs) -> cbMaxHp (bsPlayer bs)
        _ -> psMaxHp st
      qi = case (cmInBattle m, cmPresentation m, cmBattleSnap m) of
        (True, Just pr, _) -> prPlayerQi pr
        (True, Nothing, Just bs) -> cbQi (bsPlayer bs)
        _ -> psQi st
      mqi = case (cmInBattle m, cmBattleSnap m) of
        (True, Just bs) -> cbMaxQi (bsPlayer bs)
        _ -> psMaxQi st
   in (hp, mhp, qi, mqi)

enemyVitals :: ClientModel -> (Text, Int, Int, Int, Int)
enemyVitals m =
  let name = maybe "对手" (cbName . bsEnemy) (cmBattleSnap m)
      hp = case (cmPresentation m, cmBattleSnap m) of
        (Just pr, _) -> prEnemyHp pr
        (Nothing, Just bs) -> cbHp (bsEnemy bs)
        _ -> 0
      mhp = maybe 1 (cbMaxHp . bsEnemy) (cmBattleSnap m)
      qi = case (cmPresentation m, cmBattleSnap m) of
        (Just pr, _) -> prEnemyQi pr
        (Nothing, Just bs) -> cbQi (bsEnemy bs)
        _ -> 0
      mqi = maybe 1 (cbMaxQi . bsEnemy) (cmBattleSnap m)
   in (name, hp, mhp, qi, mqi)

currentMapName :: ClientModel -> Text
currentMapName m = case cmMapOverview m of
  Just mo
    | T.null (cmRoomName m)
        || any (\r -> mrPos r == moCurrentPos mo && mrRoomName r == cmRoomName m) (moRooms mo) ->
        moMapName mo
  _ -> ""
