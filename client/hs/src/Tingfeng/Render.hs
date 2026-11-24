{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Tingfeng.Render
  ( buildFrameBatch,
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

buildFrameBatch :: ClientModel -> (Text, [CanvasHitbox], Int)
buildFrameBatch m =
  case cmPage m of
    PagePoseSheet -> buildPoseSheetBatch m
    _ ->
      let w = cmWidth m
          h = cmHeight m
          tSec = cmClockMs m / 1000.0
          isBattle = cmInBattle m || cmPage m == PageBattleLab

          bgCmd =
            "BG|" <> f1 w <> "|" <> f1 h <> "|" <> f2 tSec <> "|" <> (if isBattle then "1" else "0") <> "\n"
              <> "MT|" <> f1 (h * 0.48) <> "|42|0.08|" <> f1 (cmCamX m - cmPanX m) <> "|#13221f|0.62\n"
              <> "MT|" <> f1 (h * 0.58) <> "|30|0.16|" <> f1 (cmCamX m - cmPanX m + 240) <> "|#0e1b18|0.78\n"
              <> "MT|" <> f1 (h * 0.69) <> "|22|0.26|" <> f1 (cmCamX m - cmPanX m + 520) <> "|#0a1412|0.90\n"

          mistCmds =
            if cmReducedMotion m
              then mempty
              else
                mconcat
                  [ let fi = fromIntegral i :: Double
                        mx = fmodPos (fi * 197.3 - (cmCamX m - cmPanX m) * 0.22 + tSec * (9.0 + fromIntegral (i `mod` 4) * 3.0)) w
                        my = fmodPos (fi * 131.7 - (cmCamY m - cmPanY m) * 0.14 + sin (tSec * 0.65 + fi) * 14.0) (h * 0.76)
                        mr = 1.3 + fromIntegral (i `mod` 3) * 0.8
                        ma = 0.07 + 0.05 * sin (tSec * 1.1 + fi)
                     in "CI|" <> f1 mx <> "|" <> f1 my <> "|" <> f1 mr <> "|#cfe6de||0|" <> f2 ma <> "\n"
                    | i <- [1 .. 16 :: Int]
                  ]

          (sceneB, sceneHits, sceneCnt)
            | not (cmConnected m) && cmPage m == PageGame = buildOnboardingBackdrop m
            | isBattle = buildBattleStage m
            | otherwise = buildMapStage m

          bannerCmd = case cmTransitionBanner m of
            Nothing -> mempty
            Just (txt, remMs) ->
              let al = min 1.0 (remMs / 350.0)
                  bw = min (w - 40.0) (max 200.0 (fromIntegral (T.length txt) * 20.0 + 56.0))
               in "RR|" <> f1 ((w - bw) * 0.5) <> "|" <> f1 (h * 0.22) <> "|" <> f1 bw <> "|44|8|#121d1a|#e6cf95|1.8|" <> f2 (al * 0.94) <> "\n"
                    <> "TX|" <> f1 (w * 0.5) <> "|" <> f1 (h * 0.22 + 28.0) <> "|17|700|center|#f8eed8|" <> f2 al <> "|" <> sanitize txt <> "\n"

          totalB = bgCmd <> mistCmds <> sceneB <> bannerCmd
       in (TL.toStrict (B.toLazyText totalB), sceneHits, 20 + sceneCnt)

-- Calm Martial Silhouette Backdrop during Onboarding / Character Creation
buildOnboardingBackdrop :: ClientModel -> (B.Builder, [CanvasHitbox], Int)
buildOnboardingBackdrop m =
  let w = cmWidth m
      h = cmHeight m
      breath = if cmReducedMotion m then 0.1 else sin (cmClockMs m / 520.0) * 0.14 + 0.14
      cc = cmCreateChoice m
      prof = if cmLoginMode m == "create" then parseVisualProfile (ccGender cc) else ProfileFemale
      pose = blendPose (cmPoseLib m) "idle" "guard" breath StyleSword
      ax = if w > 900 then w * 0.78 else w * 0.5
      ay = if w > 900 then h * 0.62 else h * 0.86
      sc = if w > 900 then 1.08 else 0.78
      (ac, cnt) = encodeActor ax ay sc 0.0 "#cfdfd9" "#08110f" 0.0 0.55 pose StyleSword prof (cmLookStyle m) (0, 0) (cmClockMs m)
   in ("CI|" <> f1 ax <> "|" <> f1 (ay - 84.0) <> "|110|#162b26||0|0.32\n" <> ac, [], cnt + 1)

-- Exploration Map Stage (with Frustum Culling, Pan/Zoom, Room-Kind Accents & Cross-Map Portals)
buildMapStage :: ClientModel -> (B.Builder, [CanvasHitbox], Int)
buildMapStage m =
  let w = cmWidth m
      h = cmHeight m
      loc = cmLocale m
      isMobile = w <= 768.0
      zoom = cmMapZoom m
      centerX = w * 0.5 + cmPanX m - cmCamX m * zoom
      centerY = (if isMobile then h * 0.42 else h * 0.44) + cmPanY m - cmCamY m * zoom
      tSec = cmClockMs m / 1000.0
      pulse = if cmReducedMotion m then 1.0 else 1.0 + 0.13 * sin (tSec * 3.2)

      exitByRoomId = M.fromList [(reRoomId e, reDirection e) | e <- cmRoomExits m, not (T.null (reRoomId e))]
      exitByPos = M.fromList [(pos, reDirection e) | e <- cmRoomExits m, Just pos <- [rePos e]]

      inFrustum sx sy = sx >= -150.0 && sx <= w + 150.0 && sy >= -90.0 && sy <= h + 90.0

      (mapB, mapHits, mapCnt) = case cmMapOverview m of
        Just mo | not (null (moRooms mo)) ->
          let curPos = moCurrentPos mo
              edgeCmds =
                mconcat
                  [ let (x1, y1) = worldPosFromGrid (meFrom e)
                        (x2, y2) = worldPosFromGrid (meTo e)
                        sx1 = centerX + x1 * zoom
                        sy1 = centerY + y1 * zoom
                        sx2 = centerX + x2 * zoom
                        sy2 = centerY + y2 * zoom
                        vis = inFrustum sx1 sy1 || inFrustum sx2 sy2
                        isNear = meFrom e == curPos || meTo e == curPos
                        crossMap = not (T.null (meToMapId e)) && meToMapId e /= moMapId mo
                        col
                          | crossMap = "#d6b778"
                          | isNear = "#6ec2ab"
                          | otherwise = "#34524a"
                        lw = (if isNear then 2.4 else 1.4) * min 1.2 zoom
                        al = if isNear then 0.88 else 0.46
                     in if not vis
                          then mempty
                          else
                            "LN|" <> f1 sx1 <> "|" <> f1 sy1 <> "|" <> f1 sx2 <> "|" <> f1 sy2 <> "|" <> f1 lw <> "|" <> col <> "|" <> f2 al <> "|" <> (if crossMap then "1" else "0") <> "\n"
                    | e <- moEdges mo
                  ]

              roomItems =
                [ let pos = mrPos r
                      (wx, wy) = worldPosFromGrid pos
                      sx = centerX + wx * zoom
                      sy = centerY + wy * zoom
                      isCur = pos == curPos
                      mDir = case M.lookup (mrRoomId r) exitByRoomId of
                        Just d -> Just d
                        Nothing -> M.lookup pos exitByPos
                      hov = case mDir of
                        Just d -> cmHovered m == Just (HitExit d)
                        Nothing -> False
                      fontSz = (if isCur then 14.0 else 12.5) * max 0.82 (min 1.18 zoom)
                      nw = max 78.0 (fromIntegral (T.length (mrRoomName r)) * (fontSz + 1.8) + 24.0)
                      nh = (if isCur then 38.0 else 32.0) * max 0.85 (min 1.15 zoom)
                      rx = sx - nw * 0.5
                      ry = sy - nh * 0.5
                      kindBorder = case mrRoomKind r of
                        "landmark" -> "#98cebe"
                        "building" -> "#9d8f6c"
                        "transit" -> "#c99b68"
                        _ -> "#2f4942"
                      (bg, bd, txtCol, lw)
                        | isCur = ("#1d3d35", "#e6cf95", "#fff7e2", 2.2)
                        | hov = ("#254b41", "#92ebcf", "#ffffff", 1.9)
                        | isJust mDir = ("#132823", "#5ca38f", "#e3f5ef", 1.6)
                        | otherwise = ("#0d1917", kindBorder, "#93afa5", 1.1)
                      pulseCmd =
                        if isCur
                          then "CI|" <> f1 sx <> "|" <> f1 sy <> "|" <> f1 (27.0 * pulse * zoom) <> "||#e6cf95|1.4|0.34\n"
                          else mempty
                      dirCmd = case mDir of
                        Just d ->
                          "TX|" <> f1 sx <> "|" <> f1 (ry - 5.0) <> "|10.5|600|center|#8fd9c4|0.92|" <> sanitize (directionLabel loc d) <> "\n"
                        Nothing -> mempty
                      cmd =
                        pulseCmd
                          <> "RR|" <> f1 rx <> "|" <> f1 ry <> "|" <> f1 nw <> "|" <> f1 nh <> "|7|" <> bg <> "|" <> bd <> "|" <> f1 lw <> "|0.96\n"
                          <> "TX|" <> f1 sx <> "|" <> f1 (sy + fontSz * 0.36) <> "|" <> f1 fontSz <> "|" <> (if isCur then "700" else "500") <> "|center|" <> txtCol <> "|1|" <> sanitize (mrRoomName r) <> "\n"
                          <> dirCmd
                      mHit = fmap (\d -> CanvasHitbox rx ry nw nh (HitExit d) "pointer") mDir
                   in (cmd, mHit)
                  | r <- moRooms mo,
                    let (wx0, wy0) = worldPosFromGrid (mrPos r),
                    inFrustum (centerX + wx0 * zoom) (centerY + wy0 * zoom)
                ]

              titleY = if isMobile then 68.0 else 74.0
              headerCmd =
                "TX|" <> f1 (w * 0.5) <> "|" <> f1 titleY <> "|12.5|600|center|#c9b88c|0.85|— " <> sanitize (moMapName mo) <> " —\n"
           in ( headerCmd <> edgeCmds <> mconcat (map fst roomItems),
                [hb | (_, Just hb) <- roomItems],
                length roomItems * 3 + 8
              )
        _ ->
          -- Radial 8-direction fallback around current room
          let cx = w * 0.5 + cmPanX m
              cy = (if isMobile then h * 0.42 else h * 0.44) + cmPanY m
              rName = if T.null (cmRoomName m) then tr loc "app.title" else cmRoomName m
              curW = max 94.0 (fromIntegral (T.length rName) * 16.5 + 32.0)
              curCmd =
                "CI|" <> f1 cx <> "|" <> f1 cy <> "|" <> f1 (30.0 * pulse) <> "||#e6cf95|1.5|0.34\n"
                  <> "RR|" <> f1 (cx - curW * 0.5) <> "|" <> f1 (cy - 20.0) <> "|" <> f1 curW <> "|40|8|#1d3d35|#e6cf95|2.2|0.96\n"
                  <> "TX|" <> f1 cx <> "|" <> f1 (cy + 5.5) <> "|14.5|700|center|#fff7e2|1|" <> sanitize rName <> "\n"
              spanDist = if isMobile then 118.0 else 162.0
              exits =
                [ let d = reDirection ex
                      (vx, vy) = directionVec d
                      exX = cx + vx * spanDist * zoom
                      exY = cy + vy * (spanDist * 0.78) * zoom
                      ew = max 82.0 (fromIntegral (T.length (reRoomName ex)) * 14.0 + 26.0)
                      eh = 33.0
                      rx = exX - ew * 0.5
                      ry = exY - eh * 0.5
                      hov = cmHovered m == Just (HitExit d)
                      bg = if hov then "#254b41" else "#132823"
                      bd = if hov then "#92ebcf" else "#5ca38f"
                      cmd =
                        "LN|" <> f1 cx <> "|" <> f1 cy <> "|" <> f1 exX <> "|" <> f1 exY <> "|1.9|#5ca38f|0.72|0\n"
                          <> "RR|" <> f1 rx <> "|" <> f1 ry <> "|" <> f1 ew <> "|" <> f1 eh <> "|7|" <> bg <> "|" <> bd <> "|1.6|0.95\n"
                          <> "TX|" <> f1 exX <> "|" <> f1 (exY + 4.8) <> "|12.5|600|center|#e6f7f1|1|" <> sanitize (reRoomName ex) <> "\n"
                          <> "TX|" <> f1 exX <> "|" <> f1 (ry - 5.0) <> "|10.5|600|center|#8fd9c4|0.9|" <> sanitize (directionLabel loc d) <> "\n"
                   in (cmd, CanvasHitbox rx ry ew eh (HitExit d) "pointer")
                  | ex <- cmRoomExits m
                ]
           in (curCmd <> mconcat (map fst exits), map snd exits, 4 + length exits * 4)

      -- Reset-camera chip if panned/zoomed
      hasPan = abs (cmPanX m) > 6.0 || abs (cmPanY m) > 6.0 || abs (cmMapZoom m - 1.0) > 0.04
      (resetCmd, resetHit) =
        if hasPan
          then
            let rx = w - 92.0
                ry = if isMobile then 66.0 else 72.0
             in ( "RR|" <> f1 rx <> "|" <> f1 ry <> "|74|28|6|#18312b|#7cd4bc|1.2|0.92\n"
                    <> "TX|" <> f1 (rx + 37.0) <> "|" <> f1 (ry + 18.0) <> "|11.5|600|center|#e8f7f2|1|" <> (if loc == Zh then "镜头归位" else "Center") <> "\n",
                  [CanvasHitbox rx ry 74 28 HitResetCam "pointer"]
                )
          else (mempty, [])

      -- Gentle standing silhouette companion on wide screens
      (avatarCmd, avatarCnt) =
        if not isMobile
          then
            let breath = if cmReducedMotion m then 0.1 else sin (cmClockMs m / 480.0) * 0.14 + 0.14
                hasSword = any (\a -> aiEnabled a && "sword" `T.isInfixOf` T.toLower (aiType a)) (cmArts m)
                st = if hasSword then StyleSword else StyleFist
                prof = parseVisualProfile (psGender (cmStats m))
                pose = blendPose (cmPoseLib m) "idle" "guard" breath st
                ax = w - 82.0
                ay = h * 0.58
                (ac, cnt) = encodeActor ax ay 0.68 0.0 "#d7ebe4" "#0a1311" 0.0 0.92 pose st prof (cmLookStyle m) (0, 0) (cmClockMs m)
             in ("CI|" <> f1 ax <> "|" <> f1 (ay + 3.0) <> "|34|#091210|#315249|1.1|0.52\n" <> ac, cnt + 1)
          else (mempty, 0)
   in (mapB <> resetCmd <> avatarCmd, resetHit <> mapHits, mapCnt + avatarCnt)

-- Full Deterministic Combat Stage (1:1 visual parity with SilhouetteBattleStage + BattleDirector)
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
      fitScale = min 1.0 ((w - 36.0) / 620.0) * scCameraScale scene
      stageCx = w * 0.5 + scCameraX scene * fitScale
      groundY = (if isMobile then h * 0.49 else min (h * 0.56) (h - 225.0)) + scShakeY scene * fitScale

      pFig = scPlayer scene
      eFig = scEnemy scene
      pPose = sampleSvgPose (cmPoseLib m) mTl SidePlayer elapsed (avStyle (fsVisual pFig)) (fsFrameId pFig) reduced
      ePose = sampleSvgPose (cmPoseLib m) mTl SideEnemy elapsed (avStyle (fsVisual eFig)) (fsFrameId eFig) reduced

      px = stageCx + (sideHome SidePlayer + fsX pFig) * fitScale
      py = groundY + fsY pFig * fitScale
      ex = stageCx + (sideHome SideEnemy + fsX eFig) * fitScale
      ey = groundY + fsY eFig * fitScale

      -- Hit-stop dramatic ink-wash shade & inversion
      inv = scInvert scene > 0.5
      shadeCmd =
        if scShade scene > 0.01
          then "RR|0|0|" <> f1 w <> "|" <> f1 h <> "|0|#050a09||0|" <> f2 (min 0.65 (scShade scene)) <> "\n"
          else mempty

      arenaCmd =
        "CI|" <> f1 (w * 0.5) <> "|" <> f1 (groundY - 88.0 * fitScale) <> "|" <> f1 (142.0 * fitScale) <> "|#172c27||0|0.34\n"
          <> "LN|" <> f1 (w * 0.08) <> "|" <> f1 (groundY + 2.0) <> "|" <> f1 (w * 0.92) <> "|" <> f1 (groundY + 2.0) <> "|2.4|#497367|0.68|0\n"
          <> "CI|" <> f1 px <> "|" <> f1 (groundY + 3.0) <> "|" <> f1 (24.0 * fitScale) <> "|#050b0a||0|0.55\n"
          <> "CI|" <> f1 ex <> "|" <> f1 (groundY + 3.0) <> "|" <> f1 (24.0 * fitScale) <> "|#050b0a||0|0.55\n"

      -- Dodge afterimage ghost
      ghostCmd =
        if scGhost scene > 0.04
          then
            case mTl of
              Just tl | tlTargetSide tl == SidePlayer ->
                fst (encodeActor (stageCx + sideHome SidePlayer * fitScale) groundY fitScale 0.0 "#9ed8c8" "#08110f" 0.0 (scGhost scene) pPose (avStyle (fsVisual pFig)) pProf (cmLookStyle m) (0, 0) (cmClockMs m))
              Just _ ->
                fst (encodeActor (stageCx + sideHome SideEnemy * fitScale) groundY (-fitScale) 0.0 "#9ed8c8" "#08110f" 0.0 (scGhost scene) ePose (avStyle (fsVisual eFig)) eProf (cmLookStyle m) (0, 0) (cmClockMs m))
              Nothing -> mempty
          else mempty

      pFill = if inv then "#ffffff" else "#dfeee8"
      eFill = if inv then "#f4ece0" else "#cbbdad"
      pFlow = if reduced then (0, 0) else (-fsX pFig * 0.09, abs (fsY pFig) * 0.2)
      eFlow = if reduced then (0, 0) else (fsX eFig * 0.09, abs (fsY eFig) * 0.2)

      (pCmd, pCnt) =
        encodeActor px py fitScale (fsAngle pFig) pFill "#08110f" (fsFlash pFig) (fsAlpha pFig) pPose (avStyle (fsVisual pFig)) pProf (cmLookStyle m) pFlow (cmClockMs m)
      (eCmd, eCnt) =
        encodeActor ex ey (-fitScale) (fsAngle eFig) eFill "#08110f" (fsFlash eFig) (fsAlpha eFig) ePose (avStyle (fsVisual eFig)) eProf (cmLookStyle m) eFlow (cmClockMs m + 360.0)

      -- Slash arc ribbon & parry ring & aura
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
                        col = if spForce (tlStaging tl) >= 0.85 then "#f5d896" else "#d8f3ea"
                     in "SLASH|" <> col <> "|" <> f1 shWx <> "," <> f1 shWy <> "," <> f2 (scTrail scene * 0.25)
                          <> ";" <> f1 midX <> "," <> f1 midY <> "," <> f2 (scTrail scene * 0.68)
                          <> ";" <> f1 tipWx <> "," <> f1 tipWy <> "," <> f2 (scTrail scene) <> "\n"
                  else mempty
              (cx0, cy0) = scContact scene
              cWx = stageCx + cx0 * fitScale * 0.65
              cWy = groundY + cy0 * fitScale
              parryRing =
                if scGuard scene > 0.04
                  then "CI|" <> f1 cWx <> "|" <> f1 cWy <> "|" <> f1 ((18.0 + (1.0 - scGuard scene) * 26.0) * fitScale) <> "||#f6df9e|2.6|" <> f2 (scGuard scene) <> "\n"
                  else mempty
              auraRing =
                if scAura scene > 0.04
                  then
                    let ux = if tlActorSide tl == SidePlayer then px else ex
                     in "CI|" <> f1 ux <> "|" <> f1 (groundY - 58.0 * fitScale) <> "|" <> f1 (44.0 * fitScale) <> "|#4cb89b|#9ef0d8|1.6|" <> f2 (scAura scene * 0.42) <> "\n"
                  else mempty
           in slashTrail <> parryRing <> auraRing

      partCmds =
        mconcat
          [ let al = max 0.0 (1.0 - ipLife p / max 0.01 (ipMaxLife p))
                rad = ipRadius p * (0.55 + 0.45 * al)
             in "CI|" <> f1 (ipX p) <> "|" <> f1 (ipY p) <> "|" <> f1 rad <> "|" <> B.fromText (ipColor p) <> "||0|" <> f2 al <> "\n"
            | p <- cmParticles m
          ]

      -- Move Stamp Seal + Per-Hit Floating Damage / Parry / Dodge Callout + Settlement Seal
      textCmd = case mTl of
        Nothing -> mempty
        Just tl
          | tlKind tl == "settlement" ->
              let al = scResultAlpha scene
               in "RR|" <> f1 (w * 0.5 - 46.0) <> "|" <> f1 (groundY - 128.0 * fitScale) <> "|92|92|12|#241412|#e6cf95|2.4|" <> f2 (al * 0.94) <> "\n"
                    <> "TX|" <> f1 (w * 0.5) <> "|" <> f1 (groundY - 68.0 * fitScale) <> "|42|700|center|#f8e8c4|" <> f2 al <> "|" <> sanitize (tlLabel tl) <> "\n"
          | otherwise ->
              let hIdx = scHitIndex scene
                  curFloat =
                    if hIdx >= 0 && hIdx < length (tlHits tl)
                      then rhFloatText (tlHits tl !! hIdx)
                      else tlFloatText tl
                  tx = if tlTargetSide tl == SidePlayer then px else ex
                  ty = groundY - (118.0 + scTextLift scene) * fitScale
                  fCol = case tlResult tl of
                    ResParry -> "#f6df9e"
                    ResDodge -> "#9fe3d0"
                    ResEffect -> "#8fe0b0"
                    ResHit -> if tlTargetSide tl == SideEnemy then "#ffcf87" else "#ff8e84"
                  floatCmd =
                    if scTextAlpha scene > 0.03 && not (T.null curFloat)
                      then
                        "TX|" <> f1 tx <> "|" <> f1 ty <> "|" <> f1 (21.0 * scTextScale scene) <> "|700|center|" <> fCol <> "|" <> f2 (scTextAlpha scene) <> "|" <> sanitize curFloat <> "\n"
                      else mempty
                  lbl = tlLabel tl
                  bw = max 116.0 (fromIntegral (T.length lbl) * 19.0 + 36.0)
                  bannerY = if isMobile then 98.0 else 108.0
                  stampCmd =
                    if tlKind tl /= "effect_tick"
                      then
                        "RR|" <> f1 (w * 0.5 - bw * 0.5) <> "|" <> f1 bannerY <> "|" <> f1 bw <> "|34|6|#191210|#d96b5c|1.6|0.90\n"
                          <> "TX|" <> f1 (w * 0.5) <> "|" <> f1 (bannerY + 23.0) <> "|16|700|center|#f9ebd2|0.96|「" <> sanitize lbl <> "」\n"
                      else mempty
               in stampCmd <> floatCmd
   in (shadeCmd <> arenaCmd <> ghostCmd <> pCmd <> eCmd <> vfxCmd <> partCmds <> textCmd, [], 12 + pCnt + eCnt + length (cmParticles m))

-- Pose Sheet Inspector Grid (/pose-sheet.html) rendered 100% by Haskell!
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
              (ac, _) = encodeActor cx cy 0.58 0.0 "#dfeee8" "#08110f" 0.0 1.0 pose StyleSword ProfileFemale (cmLookStyle m) (0, 0) 0.0
           in "RR|" <> f1 (cx - cellW * 0.46) <> "|" <> f1 (cy - 118.0) <> "|" <> f1 (cellW * 0.92) <> "|150|8|#0e1b18|#2a443d|1.1|0.92\n"
                <> "LN|" <> f1 (cx - cellW * 0.36) <> "|" <> f1 cy <> "|" <> f1 (cx + cellW * 0.36) <> "|" <> f1 cy <> "|1.2|#3c6157|0.65|0\n"
                <> ac
                <> "TX|" <> f1 cx <> "|" <> f1 (cy + 22.0) <> "|11.5|600|center|#d9ceae|1|" <> sanitize pid <> "\n"
          | (idx, pid) <- zip [0 ..] pids,
            72.0 + fromIntegral (idx `div` cols) * cellH < h + 160.0
        ]
      hdr = "TX|" <> f1 (w * 0.5) <> "|42|18|700|center|#e6cf95|1|听风录 · 纯 Haskell 剪影姿势总览（svg-poses.json 共 " <> B.fromString (show (length pids)) <> " 式）\n"
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
