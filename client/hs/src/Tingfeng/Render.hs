{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Tingfeng.Render
  ( FrameBatch (..),
    buildFrameBatch,
  )
where

import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Builder as B
import qualified Data.Text.Lazy.Builder.Int as BI
import Tingfeng.Battle
import Tingfeng.Catalog
import Tingfeng.I18n
import Tingfeng.Pose
import Tingfeng.Protocol
import Tingfeng.State
import Tingfeng.UiCanvas

data FrameBatch = FrameBatch
  { fbText :: !Text,
    fbHits :: ![CanvasHitbox],
    fbScrollZones :: ![ScrollZone],
    fbLogMaxScroll :: !Double,
    fbDrawerMaxScroll :: !Double,
    fbOnboardMaxScroll :: !Double,
    fbNpcMaxScroll :: !Double,
    fbCmdCount :: !Int
  }

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

sanitize :: Text -> B.Builder
sanitize = B.fromText . T.map (\c -> if c == '|' || c == '\n' || c == '\r' then ' ' else c)

fmodPos :: Double -> Double -> Double
fmodPos x m
  | m <= 1.0 = 0.0
  | otherwise =
      let r = x - fromIntegral (floor (x / m) :: Int) * m
       in if r < 0 then r + m else r

buildFrameBatch :: ClientModel -> FrameBatch
buildFrameBatch m =
  case cmPage m of
    PagePoseSheet ->
      let (t, hs, cnt) = buildPoseSheetBatch m
       in FrameBatch t hs [] 0 0 0 0 cnt
    _ ->
      let w = cmWidth m
          h = cmHeight m
          tSec = cmClockMs m / 1000.0
          isBattle = cmInBattle m || cmPage m == PageBattleLab

          -- Song-dynasty Xuan paper backdrop + misty ink-wash Shan-shui mountains (gradient fade)
          bgCmd =
            "BG|" <> f1 w <> "|" <> f1 h <> "|" <> f2 tSec <> "|" <> (if isBattle then "1" else "0") <> "\n"
              <> "MT|" <> f1 (h * 0.48) <> "|42|0.05|" <> f1 (cmCamX m - cmPanX m) <> "|#9f9a8e|0.20\n"
              <> "MT|" <> f1 (h * 0.60) <> "|28|0.11|" <> f1 (cmCamX m - cmPanX m + 280) <> "|#878377|0.22\n"
              <> "MT|" <> f1 (h * 0.72) <> "|20|0.19|" <> f1 (cmCamX m - cmPanX m + 560) <> "|#716c61|0.24\n"

          mistCmds =
            if cmReducedMotion m
              then mempty
              else
                mconcat
                  [ let fi = fromIntegral i :: Double
                        mx = fmodPos (fi * 211.3 - (cmCamX m - cmPanX m) * 0.18 + tSec * (6.5 + fromIntegral (i `mod` 3) * 2.5)) w
                        my = fmodPos (fi * 137.7 - (cmCamY m - cmPanY m) * 0.12 + sin (tSec * 0.55 + fi) * 12.0) (h * 0.72)
                        mr = 1.1 + fromIntegral (i `mod` 3) * 0.65
                        ma = 0.08 + 0.04 * sin (tSec * 0.9 + fi)
                     in "CI|" <> f1 mx <> "|" <> f1 my <> "|" <> f1 mr <> "|#6e6354||0|" <> f2 ma <> "\n"
                    | i <- [1 .. 12 :: Int]
                  ]

          (sceneB, sceneHits, sceneCnt)
            | not (cmConnected m) && cmPage m == PageGame = buildOnboardingBackdrop m
            | isBattle = buildBattleStage m
            | otherwise = buildMapStage m

          bannerCmd = case cmTransitionBanner m of
            Nothing -> mempty
            Just (txt, remMs) ->
              let al = min 1.0 (remMs / 350.0)
                  bw = min (w - 40.0) (max 210.0 (fromIntegral (T.length txt) * 20.0 + 60.0))
               in "RR|" <> f1 ((w - bw) * 0.5) <> "|" <> f1 (h * 0.22) <> "|" <> f1 bw <> "|44|3|#f7f1e3|#a32c22|1.6|" <> f2 (al * 0.96) <> "\n"
                    <> "TXS|" <> f1 (w * 0.5) <> "|" <> f1 (h * 0.22 + 28.0) <> "|17|700|center|#1e1a16|" <> f2 al <> "|" <> sanitize txt <> "\n"

          ui = buildUiOverlay m
          totalB = bgCmd <> mistCmds <> sceneB <> bannerCmd <> uoBuilder ui
       in FrameBatch
            { fbText = TL.toStrict (B.toLazyText totalB),
              fbHits = sceneHits <> uoHits ui,
              fbScrollZones = uoScrollZones ui,
              fbLogMaxScroll = uoLogMaxScroll ui,
              fbDrawerMaxScroll = uoDrawerMaxScroll ui,
              fbOnboardMaxScroll = uoOnboardMaxScroll ui,
              fbNpcMaxScroll = uoNpcMaxScroll ui,
              fbCmdCount = 18 + sceneCnt + uoCmdCount ui
            }

-- Calm Ink-Wash Martial Silhouette Backdrop during Onboarding / Character Creation
buildOnboardingBackdrop :: ClientModel -> (B.Builder, [CanvasHitbox], Int)
buildOnboardingBackdrop m =
  let w = cmWidth m
      h = cmHeight m
      breath = if cmReducedMotion m then 0.1 else sin (cmClockMs m / 540.0) * 0.14 + 0.14
      cc = cmCreateChoice m
      prof = if cmLoginMode m == "create" then parseVisualProfile (ccGender cc) else ProfileFemale
      pose = blendPose (cmPoseLib m) "idle" "guard" breath StyleSword
      ax = if w > 960 then w * 0.80 else w * 0.5
      ay = if w > 960 then h * 0.65 else h * 0.88
      sc = if w > 960 then 1.04 else 0.72
      (ac, cnt) = encodeActor ax ay sc 0.0 "#cfc4af" "#ece4d2" 0.0 0.96 pose StyleSword prof (cmLookStyle m) (0, 0) (cmClockMs m)
   in ("CI|" <> f1 ax <> "|" <> f1 (ay - 84.0) <> "|116|#dfd4be||0|0.48\n" <> ac, [], cnt + 1)

-- Song-Dynasty Xuan-Paper Cartographic Map Stage
buildMapStage :: ClientModel -> (B.Builder, [CanvasHitbox], Int)
buildMapStage m =
  let w = cmWidth m
      h = cmHeight m
      loc = cmLocale m
      isMobile = w <= 768.0
      zoom = cmMapZoom m
      effZoom = zoom * (if isMobile then 0.72 else 1.0)
      centerX = w * 0.5 + cmPanX m - cmCamX m * effZoom
      centerY = (if isMobile then h * 0.46 else h * 0.45) + cmPanY m - cmCamY m * effZoom
      tSec = cmClockMs m / 1000.0
      pulse = if cmReducedMotion m then 1.0 else 1.0 + 0.12 * sin (tSec * 2.8)

      inFrustum sx sy = sx >= -160.0 && sx <= w + 160.0 && sy >= -100.0 && sy <= h + 100.0

      mapValid mo =
        not (null (moRooms mo))
          && ( T.null (cmRoomName m)
                 || any (\r -> mrPos r == moCurrentPos mo && mrRoomName r == cmRoomName m) (moRooms mo)
             )

      (mapB, mapHits, mapCnt) = case cmMapOverview m of
        Just mo | mapValid mo ->
          let curPos = moCurrentPos mo
              sameMapExit e = T.null (reMapId e) || reMapId e == moMapId mo
              exitByRoomId = M.fromList [(reRoomId e, reDirection e) | e <- cmRoomExits m, sameMapExit e, not (T.null (reRoomId e))]
              exitByPos = M.fromList [(pos, reDirection e) | e <- cmRoomExits m, sameMapExit e, Just pos <- [rePos e]]

              edgeCmds =
                mconcat
                  [ let (x1, y1) = worldPosFromGrid (meFrom e)
                        (x2, y2) = worldPosFromGrid (meTo e)
                        sx1 = centerX + x1 * effZoom
                        sy1 = centerY + y1 * effZoom
                        sx2 = centerX + x2 * effZoom
                        sy2 = centerY + y2 * effZoom
                        vis = inFrustum sx1 sy1 || inFrustum sx2 sy2
                        isNear = meFrom e == curPos || meTo e == curPos
                        col = if isNear then "#2a564a" else "#8f8575"
                        lw = (if isNear then 1.8 else 0.9) * min 1.2 zoom
                        al = if isNear then 0.72 else 0.30
                     in if not vis
                          then mempty
                          else
                            "LN|" <> f1 sx1 <> "|" <> f1 sy1 <> "|" <> f1 sx2 <> "|" <> f1 sy2 <> "|" <> f1 lw <> "|" <> col <> "|" <> f2 al <> "|0\n"
                    | e <- moEdges mo,
                      T.null (meToMapId e) || meToMapId e == moMapId mo
                  ]

              roomItems =
                [ let pos = mrPos r
                      (wx, wy) = worldPosFromGrid pos
                      sx = centerX + wx * effZoom
                      sy = centerY + wy * effZoom
                      isCur = pos == curPos
                      mDir = case M.lookup (mrRoomId r) exitByRoomId of
                        Just d -> Just d
                        Nothing -> M.lookup pos exitByPos
                      hov = case mDir of
                        Just d -> cmHovered m == Just (HitExit d)
                        Nothing -> False
                      fontSz = (if isCur then 13.5 else 12.0) * max 0.82 (min 1.15 zoom)
                      nw = max 74.0 (fromIntegral (T.length (mrRoomName r)) * (fontSz + 1.8) + 26.0)
                      nh = (if isCur then 35.0 else 30.0) * max 0.84 (min 1.14 zoom)
                      rx = sx - nw * 0.5
                      ry = sy - nh * 0.5
                      kindAccent = case mrRoomKind r of
                        "landmark" -> "#9e2a22"
                        "transit" -> "#a67c37"
                        "building" -> "#8f8575"
                        _ -> "#b5aa98"
                      (bg, bd, txtCol, lw, shBlur, useDbl)
                        | isCur = ("#1c1915", "#b89552", "#f8f4eb", 1.1, 14.0, "1")
                        | hov = ("#fbf8f1", "#9e2a22", "#1c1915", 1.1, 12.0, "0")
                        | isJust mDir = ("#faf6ee", "rgba(42,86,74,0.42)", "#1c1915", 0.9, 8.0, "0")
                        | otherwise = ("#f1eadc", "rgba(130,118,98,0.28)", "#6b6255", 0.75, 0.0, "0")
                      pulseCmd =
                        if isCur
                          then "CI|" <> f1 sx <> "|" <> f1 sy <> "|" <> f1 (24.0 * pulse * effZoom) <> "||#b89552|1.0|0.28\n"
                          else mempty
                      accentBar =
                        if isCur
                          then "CI|" <> f1 (rx + 10.0) <> "|" <> f1 sy <> "|2.5|#b33529||0|0.95\n"
                          else
                            if isJust mDir
                              then "RR|" <> f1 (rx + 1.0) <> "|" <> f1 (ry + 5.0) <> "|2.4|" <> f1 (nh - 10.0) <> "|1|#2a564a||0|0.85\n"
                              else
                                if mrRoomKind r == "landmark" || mrRoomKind r == "transit"
                                  then "CI|" <> f1 (rx + 8.0) <> "|" <> f1 sy <> "|2.0|" <> kindAccent <> "||0|0.55\n"
                                  else mempty
                      dirCmd = case mDir of
                        Just d ->
                          "TX|" <> f1 sx <> "|" <> f1 (ry - 6.0) <> "|10|600|center|#2a564a|0.82|" <> sanitize (directionLabel loc d) <> "\n"
                        Nothing -> mempty
                      cmd =
                        pulseCmd
                          <> "CARD|" <> f1 rx <> "|" <> f1 ry <> "|" <> f1 nw <> "|" <> f1 nh <> "|3|" <> bg <> "|" <> bd <> "|" <> f1 lw <> "|" <> (if isCur || isJust mDir then "0.98" else "0.86") <> "|3|" <> f1 shBlur <> "|" <> useDbl <> "\n"
                          <> accentBar
                          <> "TXS|" <> f1 (if isCur then sx + 3.0 else sx) <> "|" <> f1 (sy + fontSz * 0.35) <> "|" <> f1 fontSz <> "|" <> (if isCur then "700" else "600") <> "|center|" <> txtCol <> "|1|" <> sanitize (mrRoomName r) <> "\n"
                          <> dirCmd
                      mHit = fmap (\d -> CanvasHitbox rx ry nw nh (HitExit d) "pointer") mDir
                   in (cmd, mHit)
                  | r <- moRooms mo,
                    let (wx0, wy0) = worldPosFromGrid (mrPos r),
                    inFrustum (centerX + wx0 * effZoom) (centerY + wy0 * effZoom)
                ]

              -- Cross-map portal edges & clickable destination portal plaques
              portalItems =
                [ let d = meDirection e
                      (x1, y1) = worldPosFromGrid (meFrom e)
                      (dgx, dgy) = directionGridDelta d
                      (x2, y2) = worldPosFromGrid (fst (meFrom e) + dgx, snd (meFrom e) + dgy)
                      sx1 = centerX + x1 * effZoom
                      sy1 = centerY + y1 * effZoom
                      sx2 = centerX + x2 * effZoom
                      sy2 = centerY + y2 * effZoom
                      isFromCur = meFrom e == curPos && any (\ex -> reDirection ex == d) (cmRoomExits m)
                      hov = isFromCur && cmHovered m == Just (HitExit d)
                      destRoom = if not (T.null (meToRoomName e)) then meToRoomName e else if not (T.null (meToMapName e)) then meToMapName e else meToMapId e
                      labelTxt = "⇄ " <> destRoom
                      fontSz = 12.0 * max 0.82 (min 1.14 zoom)
                      nw = max 86.0 (fromIntegral (T.length labelTxt) * (fontSz + 1.4) + 24.0)
                      nh = 30.0 * max 0.85 (min 1.12 zoom)
                      rx = sx2 - nw * 0.5
                      ry = sy2 - nh * 0.5
                      bg = if hov then "#ebdcb9" else if isFromCur then "#f3e8cf" else "#e9dfca"
                      bd = if hov then "#a32c22" else if isFromCur then "#946623" else "#9c8760"
                      txtCol = if isFromCur then "#4f320d" else "#6f5d42"
                      lw = if isFromCur then 1.6 else 1.1
                      al = if isFromCur then 0.92 else 0.58
                      subMap =
                        if not (T.null (meToMapName e)) && meToMapName e /= destRoom
                          then "TX|" <> f1 sx2 <> "|" <> f1 (ry + nh + 12.0) <> "|10|600|center|#8a5d1c|0.88|" <> sanitize (meToMapName e) <> "\n"
                          else mempty
                      dirCmd =
                        if isFromCur
                          then "TX|" <> f1 sx2 <> "|" <> f1 (ry - 5.0) <> "|10.5|700|center|#946623|0.95|" <> sanitize (directionLabel loc d) <> "\n"
                          else mempty
                      cmd =
                        "LN|" <> f1 sx1 <> "|" <> f1 sy1 <> "|" <> f1 sx2 <> "|" <> f1 sy2 <> "|" <> f1 lw <> "|#946623|" <> f2 al <> "|1\n"
                          <> "RR|" <> f1 rx <> "|" <> f1 ry <> "|" <> f1 nw <> "|" <> f1 nh <> "|3|" <> bg <> "|" <> bd <> "|" <> f1 lw <> "|0.97\n"
                          <> "TX|" <> f1 sx2 <> "|" <> f1 (sy2 + fontSz * 0.36) <> "|" <> f1 fontSz <> "|600|center|" <> txtCol <> "|1|" <> sanitize labelTxt <> "\n"
                          <> dirCmd
                          <> subMap
                      mHit = if isFromCur then Just (CanvasHitbox rx ry nw nh (HitExit d) "pointer") else Nothing
                   in (cmd, mHit)
                  | e <- moEdges mo,
                    not (T.null (meToMapId e)) && meToMapId e /= moMapId mo,
                    let (wx0, wy0) = worldPosFromGrid (meFrom e),
                    inFrustum (centerX + wx0 * effZoom) (centerY + wy0 * effZoom)
                ]

              coveredDirs = [d | (_, Just hb) <- roomItems <> portalItems, HitExit d <- [chTarget hb]]

              extraItems =
                [ let d = reDirection ex
                      (cx0, cy0) = worldPosFromGrid curPos
                      (dgx, dgy) = directionGridDelta d
                      (tx0, ty0) = worldPosFromGrid (fst curPos + dgx, snd curPos + dgy)
                      sx1 = centerX + cx0 * effZoom
                      sy1 = centerY + cy0 * effZoom
                      sx2 = centerX + tx0 * effZoom
                      sy2 = centerY + ty0 * effZoom
                      hov = cmHovered m == Just (HitExit d)
                      isCross = not (T.null (reMapId ex)) && reMapId ex /= moMapId mo
                      lbl = (if isCross then "⇄ " else "") <> reRoomName ex
                      ew = max 78.0 (fromIntegral (T.length lbl) * 13.4 + 24.0)
                      eh = 30.0
                      rx = sx2 - ew * 0.5
                      ry = sy2 - eh * 0.5
                      bg = if hov then "#efe4cc" else if isCross then "#f3e8cf" else "#f8f3e6"
                      bd = if hov then "#946623" else if isCross then "#946623" else "#2b594b"
                      cmd =
                        "LN|" <> f1 sx1 <> "|" <> f1 sy1 <> "|" <> f1 sx2 <> "|" <> f1 sy2 <> "|1.8|" <> bd <> "|0.82|" <> (if isCross then "1" else "0") <> "\n"
                          <> "RR|" <> f1 rx <> "|" <> f1 ry <> "|" <> f1 ew <> "|" <> f1 eh <> "|3|" <> bg <> "|" <> bd <> "|1.6|0.97\n"
                          <> "TX|" <> f1 sx2 <> "|" <> f1 (sy2 + 4.5) <> "|12|600|center|#1e1a16|1|" <> sanitize lbl <> "\n"
                          <> "TX|" <> f1 sx2 <> "|" <> f1 (ry - 5.0) <> "|10.5|700|center|" <> bd <> "|0.94|" <> sanitize (directionLabel loc d) <> "\n"
                   in (cmd, Just (CanvasHitbox rx ry ew eh (HitExit d) "pointer"))
                  | ex <- cmRoomExits m,
                    reDirection ex `notElem` coveredDirs
                ]

              allNodes = roomItems <> portalItems <> extraItems
           in ( edgeCmds <> mconcat (map fst allNodes),
                [hb | (_, Just hb) <- allNodes],
                length allNodes * 3 + 8
              )
        _ ->
          -- Radial 8-direction fallback aligned 1:1 with real grid spacing so first-time map load never jumps
          let cx = w * 0.5 + cmPanX m
              cy = (if isMobile then h * 0.46 else h * 0.45) + cmPanY m
              rName = if T.null (cmRoomName m) then tr loc "app.title" else cmRoomName m
              curW = max 92.0 (fromIntegral (T.length rName) * 15.5 + 30.0)
              curCmd =
                "CI|" <> f1 cx <> "|" <> f1 cy <> "|" <> f1 (24.0 * pulse * effZoom) <> "||#b89552|1.0|0.28\n"
                  <> "CARD|" <> f1 (cx - curW * 0.5) <> "|" <> f1 (cy - 17.5) <> "|" <> f1 curW <> "|35|3|#1c1915|#b89552|1.1|0.98|3|14|1\n"
                  <> "CI|" <> f1 (cx - curW * 0.5 + 10.0) <> "|" <> f1 cy <> "|2.5|#b33529||0|0.95\n"
                  <> "TXS|" <> f1 (cx + 3.0) <> "|" <> f1 (cy + 5.0) <> "|13.5|700|center|#f8f4eb|1|" <> sanitize rName <> "\n"
              exits =
                [ let d = reDirection ex
                      (dgx, dgy) = directionGridDelta d
                      (wx, wy) = worldPosFromGrid (dgx, dgy)
                      exX = cx + wx * effZoom
                      exY = cy + wy * effZoom
                      ew = max 74.0 (fromIntegral (T.length (reRoomName ex)) * 13.8 + 26.0)
                      eh = 30.0
                      rx = exX - ew * 0.5
                      ry = exY - eh * 0.5
                      hov = cmHovered m == Just (HitExit d)
                      bg = if hov then "#fbf8f1" else "#faf6ee"
                      bd = if hov then "#9e2a22" else "rgba(42,86,74,0.42)"
                      cmd =
                        "LN|" <> f1 cx <> "|" <> f1 cy <> "|" <> f1 exX <> "|" <> f1 exY <> "|1.8|#2a564a|0.72|0\n"
                          <> "CARD|" <> f1 rx <> "|" <> f1 ry <> "|" <> f1 ew <> "|" <> f1 eh <> "|3|" <> bg <> "|" <> bd <> "|0.9|0.98|3|8|0\n"
                          <> "RR|" <> f1 (rx + 1.0) <> "|" <> f1 (ry + 5.0) <> "|2.4|20|1|#2a564a||0|0.85\n"
                          <> "TXS|" <> f1 exX <> "|" <> f1 (exY + 4.4) <> "|12|600|center|#1c1915|1|" <> sanitize (reRoomName ex) <> "\n"
                          <> "TX|" <> f1 exX <> "|" <> f1 (ry - 6.0) <> "|10|600|center|#2a564a|0.82|" <> sanitize (directionLabel loc d) <> "\n"
                   in (cmd, CanvasHitbox rx ry ew eh (HitExit d) "pointer")
                  | ex <- cmRoomExits m
                ]
           in (curCmd <> mconcat (map fst exits), map snd exits, 4 + length exits * 5)
   in (mapB, mapHits, mapCnt)

-- Song-Dynasty Ink-Wash Combat Stage (Deep-Ink Silhouettes on Xuan Paper + Hit-Stop Inversion)
buildBattleStage :: ClientModel -> (B.Builder, [CanvasHitbox], Int)
buildBattleStage m =
  let w = cmWidth m
      h = cmHeight m
      isMobile = w <= 768.0
      pStyle = maybe StyleFist (parseCombatStyle . cbStyle . bsPlayer) (cmBattleSnap m)
      eStyle = maybe StyleSword (parseCombatStyle . cbStyle . bsEnemy) (cmBattleSnap m)
      pProf = maybe (parseVisualProfile (psGender (cmStats m))) (parseVisualProfile . cbGender . bsPlayer) (cmBattleSnap m)
      eProf = maybe ProfileMale (parseVisualProfile . cbGender . bsEnemy) (cmBattleSnap m)

      idleP = ActorVisual (idleActionIdForStyle pStyle) pProf pStyle [FrameHold "idle" 640] Nothing
      idleE = ActorVisual (idleActionIdForStyle eStyle) eProf eStyle [FrameHold "idle" 640] Nothing
      mTl = cmActiveTimeline m
      elapsed = cmTimelineElapsedMs m
      reduced = cmReducedMotion m
      scene = sampleBattleScene mTl elapsed idleP idleE reduced

      -- Scale stage smoothly to fit mobile portrait (390px) & desktop (1280px)
      fitScale = min 1.04 ((w - 32.0) / 580.0) * scCameraScale scene
      stageCx = w * 0.5 + scCameraX scene * fitScale
      groundY = (if isMobile then h * 0.51 else min (h * 0.58) (h - 230.0)) + scShakeY scene * fitScale

      pFig = scPlayer scene
      eFig = scEnemy scene
      pPose = sampleSvgPose (cmPoseLib m) mTl SidePlayer elapsed (avStyle (fsVisual pFig)) (fsFrameId pFig) reduced
      ePose = sampleSvgPose (cmPoseLib m) mTl SideEnemy elapsed (avStyle (fsVisual eFig)) (fsFrameId eFig) reduced

      px = stageCx + (sideHome SidePlayer + fsX pFig) * fitScale
      py = groundY + fsY pFig * fitScale
      ex = stageCx + (sideHome SideEnemy + fsX eFig) * fitScale
      ey = groundY + fsY eFig * fitScale

      -- Hit-stop dramatic ink-wash shade & classic Wuxia inversion
      inv = scInvert scene > 0.5
      shadeCmd =
        if inv
          then "RR|0|0|" <> f1 w <> "|" <> f1 h <> "|0|#1a1612||0|0.82\n"
          else
            if scShade scene > 0.01
              then "RR|0|0|" <> f1 w <> "|" <> f1 h <> "|0|#2b241c||0|" <> f2 (min 0.24 (scShade scene * 0.45)) <> "\n"
              else mempty

      moonCol = if inv then "#352e26" else "#dfd4be"
      horizonCol = if inv then "#d6cab2" else "#3a3228"
      shadowCol = if inv then "#000000" else "#1e1a16"
      shadowAlpha = if inv then "0.35" else "0.18"

      arenaCmd =
        "CI|" <> f1 (w * 0.5) <> "|" <> f1 (groundY - 90.0 * fitScale) <> "|" <> f1 (138.0 * fitScale) <> "|" <> moonCol <> "||0|0.55\n"
          <> "LN|" <> f1 (w * 0.08) <> "|" <> f1 (groundY + 2.0) <> "|" <> f1 (w * 0.92) <> "|" <> f1 (groundY + 2.0) <> "|2.0|" <> horizonCol <> "|0.58|0\n"
          <> "ELL|" <> f1 px <> "|" <> f1 (groundY + 3.0) <> "|" <> f1 (28.0 * fitScale) <> "|" <> f1 (5.5 * fitScale) <> "|" <> shadowCol <> "|" <> shadowAlpha <> "\n"
          <> "ELL|" <> f1 ex <> "|" <> f1 (groundY + 3.0) <> "|" <> f1 (28.0 * fitScale) <> "|" <> f1 (5.5 * fitScale) <> "|" <> shadowCol <> "|" <> shadowAlpha <> "\n"

      -- Dodge ink afterimage ghost
      ghostCmd =
        if scGhost scene > 0.04
          then
            case mTl of
              Just tl | tlTargetSide tl == SidePlayer ->
                fst (encodeActor (stageCx + sideHome SidePlayer * fitScale) groundY fitScale 0.0 "#2b594b" "#f6f0e2" 0.0 (scGhost scene * 0.65) pPose (avStyle (fsVisual pFig)) pProf (cmLookStyle m) (0, 0) (cmClockMs m))
              Just _ ->
                fst (encodeActor (stageCx + sideHome SideEnemy * fitScale) groundY (-fitScale) 0.0 "#6e6354" "#f6f0e2" 0.0 (scGhost scene * 0.65) ePose (avStyle (fsVisual eFig)) eProf (cmLookStyle m) (0, 0) (cmClockMs m))
              Nothing -> mempty
          else mempty

      -- Deep ink silhouettes on warm paper; stark Xuan-paper white during hit-stop inversion
      (pFill, eFill, outlineCol) =
        if inv
          then ("#f6f0e2", "#e6d8be", "#181410")
          else ("#1b2521", "#2f221b", "#f6f0e2")
      pFlow = if reduced then (0, 0) else (-fsX pFig * 0.09, abs (fsY pFig) * 0.2)
      eFlow = if reduced then (0, 0) else (fsX eFig * 0.09, abs (fsY eFig) * 0.2)

      (pCmd, pCnt) =
        encodeActor px py fitScale (fsAngle pFig) pFill outlineCol (fsFlash pFig) (fsAlpha pFig) pPose (avStyle (fsVisual pFig)) pProf (cmLookStyle m) pFlow (cmClockMs m)
      (eCmd, eCnt) =
        encodeActor ex ey (-fitScale) (fsAngle eFig) eFill outlineCol (fsFlash eFig) (fsAlpha eFig) ePose (avStyle (fsVisual eFig)) eProf (cmLookStyle m) eFlow (cmClockMs m + 360.0)

      -- Slash arc ribbon, parry ring & focus aura
      vfxCmd = case mTl of
        Nothing -> mempty
        Just tl ->
          let actorIsP = tlActorSide tl == SidePlayer
              aStyle = if actorIsP then avStyle (fsVisual pFig) else avStyle (fsVisual eFig)
              aPose = if actorIsP then pPose else ePose
              ax = if actorIsP then px else ex
              ay = if actorIsP then py else ey
              sgn = if actorIsP then fitScale else -fitScale
              (tipLx, tipLy) = if aStyle == StyleSword then swordTipOf aPose else spHand aPose
              tipWx = ax + sgn * tipLx
              tipWy = ay + abs fitScale * tipLy
              (shLx, shLy) = spShoulder aPose
              shWx = ax + sgn * shLx
              shWy = ay + abs fitScale * shLy
              slashTrail =
                if scTrail scene > 0.04
                  then
                    let midX = (shWx + tipWx) * 0.5 + (if actorIsP then 18.0 else -18.0) * fitScale
                        midY = min shWy tipWy - 24.0 * fitScale
                        col
                          | inv = "#f6f0e2"
                          | spForce (tlStaging tl) >= 0.85 = "#a32c22"
                          | otherwise = "#2b594b"
                     in "SLASH|" <> col <> "|" <> f1 shWx <> "," <> f1 shWy <> "," <> f2 (scTrail scene * 0.28)
                          <> ";" <> f1 midX <> "," <> f1 midY <> "," <> f2 (scTrail scene * 0.72)
                          <> ";" <> f1 tipWx <> "," <> f1 tipWy <> "," <> f2 (scTrail scene) <> "\n"
                  else mempty
              (cx0, cy0) = scContact scene
              cWx = stageCx + cx0 * fitScale * 0.65
              cWy = groundY + cy0 * fitScale
              parryRing =
                if scGuard scene > 0.04
                  then "CI|" <> f1 cWx <> "|" <> f1 cWy <> "|" <> f1 ((18.0 + (1.0 - scGuard scene) * 26.0) * fitScale) <> "||#946623|2.6|" <> f2 (scGuard scene) <> "\n"
                  else mempty
              auraRing =
                if scAura scene > 0.04
                  then
                    let ux = if tlActorSide tl == SidePlayer then px else ex
                     in "CI|" <> f1 ux <> "|" <> f1 (groundY - 58.0 * fitScale) <> "|" <> f1 (44.0 * fitScale) <> "|#2b594b|#386944|1.6|" <> f2 (scAura scene * 0.28) <> "\n"
                  else mempty
           in slashTrail <> parryRing <> auraRing

      -- Canvas2D expanding ink/cinnabar impact shockwave ripple
      shockCmd =
        if not reduced && cmShockAge m < 0.44 && cmShockPower m > 0.05
          then
            let age = cmShockAge m
                pwr = min 1.2 (cmShockPower m)
                (su, sv) = cmShockPos m
                sx = su * w
                sy = (1.0 - sv) * h
                rad1 = (18.0 + age * 260.0) * fitScale
                rad2 = (10.0 + age * 180.0) * fitScale
                al1 = max 0.0 (1.0 - age / 0.44) * 0.45 * pwr
                al2 = max 0.0 (1.0 - age / 0.34) * 0.28 * pwr
                col1 = if inv then "#f6f0e2" else "#a32c22"
                col2 = if inv then "#d6cab2" else "#946623"
             in "CI|" <> f1 sx <> "|" <> f1 sy <> "|" <> f1 rad1 <> "||" <> col1 <> "|2.0|" <> f2 al1 <> "\n"
                  <> "CI|" <> f1 sx <> "|" <> f1 sy <> "|" <> f1 rad2 <> "||" <> col2 <> "|1.2|" <> f2 al2 <> "\n"
          else mempty

      partCmds =
        mconcat
          [ let al = max 0.0 (1.0 - ipLife p / max 0.01 (ipMaxLife p))
                rad = ipRadius p * (0.55 + 0.45 * al)
             in "CI|" <> f1 (ipX p) <> "|" <> f1 (ipY p) <> "|" <> f1 rad <> "|" <> B.fromText (ipColor p) <> "||0|" <> f2 al <> "\n"
            | p <- cmParticles m
          ]

      -- Move Stamp Seal + Floating Damage / Parry / Dodge Callout + Cinnabar Settlement Seal
      textCmd = case mTl of
        Nothing -> mempty
        Just tl
          | tlKind tl == "settlement" ->
              let al = scResultAlpha scene
               in "RR|" <> f1 (w * 0.5 - 46.0) <> "|" <> f1 (groundY - 130.0 * fitScale) <> "|92|92|4|#a32c22|#f6f0e2|2.5|" <> f2 (al * 0.96) <> "\n"
                    <> "TX|" <> f1 (w * 0.5) <> "|" <> f1 (groundY - 70.0 * fitScale) <> "|42|700|center|#f6f0e2|" <> f2 al <> "|" <> sanitize (tlLabel tl) <> "\n"
          | otherwise ->
              let hIdx = scHitIndex scene
                  curFloat =
                    if hIdx >= 0 && hIdx < length (tlHits tl)
                      then rhFloatText (tlHits tl !! hIdx)
                      else tlFloatText tl
                  tx = if tlTargetSide tl == SidePlayer then px else ex
                  ty = groundY - (122.0 + scTextLift scene) * fitScale
                  fCol = case tlResult tl of
                    ResParry -> "#946623"
                    ResDodge -> "#2b594b"
                    ResEffect -> "#386944"
                    ResHit -> if inv then "#ffdf9e" else if tlTargetSide tl == SideEnemy then "#a32c22" else "#8f1f16"
                  floatCmd =
                    if scTextAlpha scene > 0.03 && not (T.null curFloat)
                      then
                        "TX|" <> f1 tx <> "|" <> f1 ty <> "|" <> f1 (22.0 * scTextScale scene) <> "|700|center|" <> fCol <> "|" <> f2 (scTextAlpha scene) <> "|" <> sanitize curFloat <> "\n"
                      else mempty
                  lbl = tlLabel tl
                  bw = max 118.0 (fromIntegral (T.length lbl) * 18.5 + 40.0)
                  bannerY = if isMobile then 186.0 else 156.0
                  stampCmd =
                    if tlKind tl /= "effect_tick"
                      then
                        "RR|" <> f1 (w * 0.5 - bw * 0.5) <> "|" <> f1 bannerY <> "|" <> f1 bw <> "|34|3|#f7f1e3|#a32c22|1.5|0.94\n"
                          <> "TX|" <> f1 (w * 0.5) <> "|" <> f1 (bannerY + 23.0) <> "|15.5|700|center|#1e1a16|0.98|「" <> sanitize lbl <> "」\n"
                      else mempty
               in stampCmd <> floatCmd
   in (shadeCmd <> arenaCmd <> ghostCmd <> pCmd <> eCmd <> vfxCmd <> shockCmd <> partCmds <> textCmd, [], 14 + pCnt + eCnt + length (cmParticles m))

-- Pose Sheet Inspector Grid (/pose-sheet.html) rendered in Xuan-paper ink style
buildPoseSheetBatch :: ClientModel -> (Text, [CanvasHitbox], Int)
buildPoseSheetBatch m =
  let w = cmWidth m
      h = cmHeight m
      pids = allPoseIds (cmPoseLib m)
      cols = max 2 (floor ((w - 40.0) / 176.0))
      cellW = (w - 40.0) / fromIntegral cols
      cellH = 168.0
      bg = "BG|" <> f1 w <> "|" <> f1 h <> "|0|0\n"
      cells =
        [ let col = idx `mod` cols
              row = idx `div` cols
              cx = 20.0 + fromIntegral col * cellW + cellW * 0.5
              cy = 72.0 + fromIntegral row * cellH + 126.0
              pose = svgPose (cmPoseLib m) pid StyleSword
              (ac, _) = encodeActor cx cy 0.58 0.0 "#1e2320" "#f6f0e2" 0.0 1.0 pose StyleSword ProfileFemale (cmLookStyle m) (0, 0) 0.0
           in "RR|" <> f1 (cx - cellW * 0.46) <> "|" <> f1 (cy - 118.0) <> "|" <> f1 (cellW * 0.92) <> "|150|3|#f6f0e2|#c8bca4|1.1|0.95\n"
                <> "LN|" <> f1 (cx - cellW * 0.36) <> "|" <> f1 cy <> "|" <> f1 (cx + cellW * 0.36) <> "|" <> f1 cy <> "|1.2|#6e6354|0.55|0\n"
                <> ac
                <> "TX|" <> f1 cx <> "|" <> f1 (cy + 22.0) <> "|11.5|600|center|#3d352c|1|" <> sanitize pid <> "\n"
          | (idx, pid) <- zip [0 ..] pids,
            72.0 + fromIntegral (idx `div` cols) * cellH < h + 160.0
        ]
      hdr = "TX|" <> f1 (w * 0.5) <> "|42|18|700|center|#1e1a16|1|听风录 · 宣纸剪影姿势总览（svg-poses.json 共 " <> B.fromString (show (length pids)) <> " 式）\n"
   in (TL.toStrict (B.toLazyText (bg <> hdr <> mconcat cells)), [], length pids * 12)

encodeActor ::
  Double ->
  Double ->
  Double ->
  Double ->
  B.Builder ->
  B.Builder ->
  Double ->
  Double ->
  SvgPose ->
  CombatStyle ->
  VisualProfile ->
  LookStyle ->
  Pt ->
  Double ->
  (B.Builder, Int)
encodeActor wx wy scaleSign rotDeg fillCol outlineCol flash alpha pose style prof look hairFlow clockMs =
  let parts = buildActorParts pose style prof look hairFlow clockMs
      encShape (SCircle cx cy r mFill op) =
        "ACIRC|" <> f1 cx <> "|" <> f1 cy <> "|" <> f1 r <> "|" <> maybe mempty B.fromText mFill <> "|" <> f2 (op * alpha) <> "\n"
      encShape (SPoly pts mFill op) =
        "APOLY|"
          <> maybe mempty B.fromText mFill
          <> "|"
          <> f2 (op * alpha)
          <> "|"
          <> mconcat
            [ (if idx > (0 :: Int) then "," else mempty) <> f1 px <> "," <> f1 py
              | (idx, (px, py)) <- zip [0 ..] pts
            ]
          <> "\n"
      encJoin (JoinPatch (jx, jy) jr jShapes) =
        "AJOIN_BEGIN|" <> f1 jx <> "|" <> f1 jy <> "|" <> f1 jr <> "\n"
          <> mconcat (map encShape jShapes)
          <> "AJOIN_END\n"
      encPart (ActorPart _ shapes joins) =
        "APART_BEGIN|" <> f2 alpha <> "\n"
          <> mconcat (map encShape shapes)
          <> "APART_FILL\n"
          <> mconcat (map encJoin joins)
      body = mconcat (map encPart parts)
      cnt = sum [length (apShapes p) + length (apJoins p) * 2 | p <- parts]
   in ( "ACTOR_BEGIN|" <> f1 wx <> "|" <> f1 wy <> "|" <> f2 scaleSign <> "|" <> f1 rotDeg <> "|" <> fillCol <> "|" <> outlineCol <> "|" <> f2 flash <> "\n"
          <> body
          <> "ACTOR_END\n",
        cnt
      )
