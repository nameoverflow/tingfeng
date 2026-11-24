{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Tingfeng.Battle
  ( BattleSide (..),
    battleSideText,
    parseBattleSide,
    ActorVisual (..),
    ResolvedHit (..),
    ResolvedActor (..),
    ResolvedTarget (..),
    ResolvedTimeline (..),
    FigureSample (..),
    SceneSample (..),
    InkParticle (..),
    sideHome,
    jsRound,
    splitByShare,
    resolveCombatTimeline,
    resolveSettlementTimeline,
    visualTimeAt,
    hitIndexAt,
    reachPointAt,
    actorOffsetAt,
    sampleSvgPose,
    sampleBattleScene,
    spawnHitParticles,
  )
where

import Data.List (elemIndex, find)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Tingfeng.Catalog
import Tingfeng.Pose
import Tingfeng.Protocol

data BattleSide = SidePlayer | SideEnemy
  deriving (Show, Eq)

battleSideText :: BattleSide -> Text
battleSideText SidePlayer = "player"
battleSideText SideEnemy = "enemy"

parseBattleSide :: Text -> BattleSide
parseBattleSide "enemy" = SideEnemy
parseBattleSide _ = SidePlayer

sideHome :: BattleSide -> Double
sideHome SidePlayer = -230.0
sideHome SideEnemy = 230.0

data ActorVisual = ActorVisual
  { avActionId :: !Text,
    avProfile :: !VisualProfile,
    avStyle :: !CombatStyle,
    avFrames :: ![FrameHold],
    avKeyPoses :: !(Maybe KeyPosesDef)
  }
  deriving (Show, Eq)

data ResolvedHit = ResolvedHit
  { rhAtMs :: !Double,
    rhHitStopMs :: !Double,
    rhDamage :: !(Maybe Int),
    rhHeal :: !(Maybe Int),
    rhFloatText :: !Text,
    rhResult :: !CombatResult,
    rhReaction :: !TargetReaction,
    rhTargetVisual :: !ActorVisual,
    rhStaging :: !StagingProfile
  }
  deriving (Show, Eq)

data ResolvedActor = ResolvedActor
  { raSide :: !BattleSide,
    raVisual :: !ActorVisual,
    raMotion :: !Text,
    raApproach :: !(Maybe ApproachDef),
    raPoseKeys :: ![PoseKey],
    raOffsetKeys :: ![OffsetKey],
    raActionDelayMs :: !Double
  }
  deriving (Show, Eq)

data ResolvedTarget = ResolvedTarget
  { rtSide :: !BattleSide,
    rtVisual :: !ActorVisual,
    rtReaction :: !TargetReaction
  }
  deriving (Show, Eq)

data ResolvedTimeline = ResolvedTimeline
  { tlId :: !Int,
    tlKind :: !Text,
    tlActorSide :: !BattleSide,
    tlTargetSide :: !BattleSide,
    tlDurationMs :: !Double,
    tlImpactAtMs :: !Double,
    tlHits :: ![ResolvedHit],
    tlStaging :: !StagingProfile,
    tlLabel :: !Text,
    tlChoreography :: !Choreography,
    tlActor :: !ResolvedActor,
    tlTarget :: !ResolvedTarget,
    tlResult :: !CombatResult,
    tlDamage :: !(Maybe Int),
    tlHeal :: !(Maybe Int),
    tlFloatText :: !Text,
    tlText :: !Text
  }
  deriving (Show, Eq)

data FigureSample = FigureSample
  { fsVisual :: !ActorVisual,
    fsFrameId :: !Text,
    fsX :: !Double,
    fsY :: !Double,
    fsAngle :: !Double,
    fsAlpha :: !Double,
    fsFlash :: !Double
  }
  deriving (Show, Eq)

data SceneSample = SceneSample
  { scPlayer :: !FigureSample,
    scEnemy :: !FigureSample,
    scPhase :: !Text,
    scCameraScale :: !Double,
    scCameraX :: !Double,
    scShakeY :: !Double,
    scShade :: !Double,
    scTrail :: !Double,
    scBurst :: !Double,
    scGuard :: !Double,
    scAura :: !Double,
    scGhost :: !Double,
    scInvert :: !Double,
    scAngle :: !Double,
    scTextAlpha :: !Double,
    scTextLift :: !Double,
    scTextScale :: !Double,
    scContact :: !Pt,
    scForce :: !Double,
    scHitIndex :: !Int,
    scResultAlpha :: !Double
  }
  deriving (Show, Eq)

data InkParticle = InkParticle
  { ipX :: !Double,
    ipY :: !Double,
    ipVx :: !Double,
    ipVy :: !Double,
    ipRadius :: !Double,
    ipLife :: !Double,
    ipMaxLife :: !Double,
    ipColor :: !Text
  }
  deriving (Show, Eq)

-- JavaScript Math.round semantics: floor(x + 0.5)
jsRound :: Double -> Int
jsRound x = floor (x + 0.5)

splitByShare :: Maybe Int -> [Double] -> [Maybe Int]
splitByShare Nothing shares = map (const Nothing) shares
splitByShare (Just total) shares =
  let sumS = max 1e-6 (sum shares)
      go _ _ [] = []
      go !before !acc (s : rest) =
        let acc' = acc + s
            upTo = jsRound (fromIntegral total * acc' / sumS)
            part = upTo - before
         in Just part : go upTo acc' rest
   in go 0 0.0 shares

clipImpactOffsetMs :: [FrameHold] -> Int -> Double -> Double
clipImpactOffsetMs frames impactIdx playbackMs =
  let totalHold = max 1.0 (sum (map fhHoldMs frames))
      beforeHold = sum (map fhHoldMs (take (max 0 impactIdx) frames))
   in beforeHold * playbackMs / totalHold

clipFrameAt :: [FrameHold] -> Double -> Double -> Text
clipFrameAt [] _ _ = "idle"
clipFrameAt frames elapsed totalDur =
  let rawSum = max 1.0 (sum (map fhHoldMs frames))
      scaledT = max 0.0 (min rawSum (elapsed * rawSum / max 1.0 totalDur))
      go _ [f] = fhFrameId f
      go !acc (f : fs) =
        let acc' = acc + fhHoldMs f
         in if scaledT < acc' then fhFrameId f else go acc' fs
      go _ [] = "idle"
   in go 0.0 frames

visualForAction :: ActionCatalog -> Text -> VisualProfile -> CombatStyle -> ActorVisual
visualForAction cat aid prof fallbackStyle =
  let a = battleActionFor cat aid fallbackStyle
   in ActorVisual (adId a) prof (adStyle a) (adFrames a) (adKeyPoses a)

idleVisual :: ActionCatalog -> CombatStyle -> VisualProfile -> ActorVisual
idleVisual cat style prof = visualForAction cat (idleActionIdForStyle style) prof style

reactionVisual :: ActionCatalog -> TargetReaction -> VisualProfile -> CombatStyle -> ActorVisual
reactionVisual cat react prof style
  | react == ReactEffect || react == ReactNone = idleVisual cat style prof
  | otherwise = visualForAction cat (reactionActionIdForStyle react style) prof style

floatTextOf :: CombatResult -> Maybe Int -> Maybe Int -> Text
floatTextOf res mDmg mHeal
  | Just d <- mDmg, d > 0 = "-" <> T.pack (show d)
  | Just h <- mHeal, h > 0 = "+" <> T.pack (show h)
  | res == ResDodge = "闪"
  | res == ResParry = "架"
  | otherwise = ""

resultReaction :: CombatResult -> TargetReaction
resultReaction ResHit = ReactHit
resultReaction ResDodge = ReactDodge
resultReaction ResParry = ReactParry
resultReaction ResEffect = ReactEffect

resolveCombatTimeline ::
  ActionCatalog ->
  CombatEvt ->
  Int ->
  BattleSide ->
  BattleSide ->
  Text ->
  VisualProfile ->
  VisualProfile ->
  CombatStyle ->
  CombatStyle ->
  ResolvedTimeline
resolveCombatTimeline cat ev tid actorSide targetSide logTxt actorProf targetProf actorStyle targetStyle =
  let action = battleActionFor cat (ceActionId ev) actorStyle
      actorVis = ActorVisual (adId action) actorProf (adStyle action) (adFrames action) (adKeyPoses action)
      actionDur = case ceDurationMs ev of
        Just d | d > 0 && not (isNaN d) && not (isInfinite d) -> fromIntegral (jsRound d)
        _ -> adDurationMs action
      mApproach = if ceKind ev == "effect_tick" then Nothing else adApproach action
      delayMs = maybe 0.0 apDurationMs mApproach * actionDur / max 1.0 (adDurationMs action)
      scale = actionDur / max 1.0 (adDurationMs action)
      c0 = adChoreography action

      rawHits =
        if not (null (adHits action))
          then
            [ (delayMs + hdAtMs h * scale, hdHitStopMs h * scale, hdShare h, hdStaging h)
              | h <- adHits action
            ]
          else
            [ ( delayMs + clipImpactOffsetMs (adFrames action) (adImpactFrame action) actionDur,
                chHitStopMs c0 * scale,
                1.0,
                Nothing
              )
            ]

      hasOutcomes = length (ceHits ev) == length rawHits
      shares = [sh | (_, _, sh, _) <- rawHits]
      dmgParts = if hasOutcomes then map chDamage (ceHits ev) else splitByShare (ceDamage ev) shares
      healParts = if hasOutcomes then map chHeal (ceHits ev) else splitByShare (ceHeal ev) shares

      hits =
        [ let res = if hasOutcomes then chResult (ceHits ev !! idx) else ceResult ev
              react = M.findWithDefault (resultReaction res) res (adTargetReaction action)
              stg = stagingFor cat (chWeight c0) [adStaging action, ceStagingOverride ev, hStg]
              dmg = dmgParts !! idx
              hl = healParts !! idx
           in ResolvedHit
                { rhAtMs = atT,
                  rhHitStopMs = stopT,
                  rhDamage = dmg,
                  rhHeal = hl,
                  rhFloatText = floatTextOf res dmg hl,
                  rhResult = res,
                  rhReaction = react,
                  rhTargetVisual = reactionVisual cat react targetProf targetStyle,
                  rhStaging = stg
                }
          | (idx, (atT, stopT, _, hStg)) <- zip [0 ..] rawHits
        ]

      firstHit = head hits
      choreo =
        c0
          { chLaunchAtMs = delayMs + chLaunchAtMs c0 * scale,
            chHitStopMs = rhHitStopMs firstHit,
            chRecoverAtMs = delayMs + chRecoverAtMs c0 * scale,
            chRestAtMs = delayMs + chRestAtMs c0 * scale
          }

      poseKeys = resolvePoseKeys action choreo hits delayMs scale
      offsetKeys = [ok {okAtMs = delayMs + okAtMs ok * scale} | ok <- adOffsetTrack action]
      lbl = case ceLabel ev of
        Just l | not (T.null (T.strip l)) -> T.strip l
        _ ->
          let st = T.strip (ceText ev)
           in if ceMsgKind ev == "script" && not (T.null st) && T.length st <= 12
                then st
                else adLabel action
   in ResolvedTimeline
        { tlId = tid,
          tlKind = ceKind ev,
          tlActorSide = actorSide,
          tlTargetSide = targetSide,
          tlDurationMs = actionDur + delayMs,
          tlImpactAtMs = rhAtMs firstHit,
          tlHits = hits,
          tlStaging = stagingFor cat (chWeight c0) [adStaging action, ceStagingOverride ev],
          tlLabel = lbl,
          tlChoreography = choreo,
          tlActor =
            ResolvedActor
              { raSide = actorSide,
                raVisual = actorVis,
                raMotion = adActorMotion action,
                raApproach = mApproach,
                raPoseKeys = poseKeys,
                raOffsetKeys = offsetKeys,
                raActionDelayMs = delayMs
              },
          tlTarget =
            ResolvedTarget
              { rtSide = targetSide,
                rtVisual = rhTargetVisual firstHit,
                rtReaction = rhReaction firstHit
              },
          tlResult = rhResult firstHit,
          tlDamage = ceDamage ev,
          tlHeal = ceHeal ev,
          tlFloatText = floatTextOf (ceResult ev) (ceDamage ev) (ceHeal ev),
          tlText = logTxt
        }

resolvePoseKeys :: ActionDef -> Choreography -> [ResolvedHit] -> Double -> Double -> [PoseKey]
resolvePoseKeys action choreo hits delayMs scale
  | adActorMotion action == "focus" = []
  | not (null (adPoseTrack action)) =
      let travels = isTravelMotion (adActorMotion action)
          retreatPose = fromMaybe "retreat" (adKeyPoses action >>= kpRetreat)
          retreatKey = PoseKey (chRecoverAtMs choreo) retreatPose Nothing Nothing Nothing
          idleKey = PoseKey (chRestAtMs choreo) "idle" Nothing Nothing Nothing
          track = [pk {pkAtMs = delayMs + pkAtMs pk * scale} | pk <- adPoseTrack action]
       in if travels
            then filter (\k -> pkAtMs k < pkAtMs retreatKey) track <> [retreatKey, idleKey]
            else track
  | otherwise =
      case adKeyPoses action of
        Just kp
          | Just prep <- kpPrepare kp,
            Just reachPin <- kpReachWith kp ->
              let travels = isTravelMotion (adActorMotion action)
                  retreatKey = PoseKey (chRecoverAtMs choreo) (fromMaybe "retreat" (kpRetreat kp)) Nothing Nothing Nothing
                  idleKey = PoseKey (chRestAtMs choreo) "idle" Nothing Nothing Nothing
                  contactPose = fromMaybe "punch_strike" (kpContact kp)
                  lastH = last hits
                  midKeys
                    | travels = [retreatKey]
                    | Just fin <- kpFinish kp = [PoseKey (rhAtMs lastH + rhHitStopMs lastH) fin Nothing Nothing Nothing]
                    | otherwise = []
               in [ PoseKey delayMs prep Nothing Nothing Nothing,
                    PoseKey (chLaunchAtMs choreo) contactPose (Just reachPin) Nothing Nothing
                  ]
                    <> midKeys
                    <> [idleKey]
        _ -> []

resolveSettlementTimeline ::
  ActionCatalog ->
  Int ->
  BattleSide ->
  BattleSide ->
  Text ->
  VisualProfile ->
  VisualProfile ->
  CombatStyle ->
  CombatStyle ->
  ResolvedTimeline
resolveSettlementTimeline cat tid actorSide targetSide txt actorProf targetProf actorStyle targetStyle =
  let aVis = idleVisual cat actorStyle actorProf
      tVis = idleVisual cat targetStyle targetProf
      stg = stagingFor cat "quiet" []
      hit = ResolvedHit 0 0 Nothing Nothing "" ResEffect ReactNone tVis stg
   in ResolvedTimeline
        { tlId = tid,
          tlKind = "settlement",
          tlActorSide = actorSide,
          tlTargetSide = targetSide,
          tlDurationMs = 900,
          tlImpactAtMs = 0,
          tlHits = [hit],
          tlStaging = stg,
          tlLabel = if actorSide == SidePlayer then "胜" else "败",
          tlChoreography = Choreography 0 0 0 900 0 100 "quiet",
          tlActor = ResolvedActor actorSide aVis "none" Nothing [] [] 0,
          tlTarget = ResolvedTarget targetSide tVis ReactNone,
          tlResult = ResEffect,
          tlDamage = Nothing,
          tlHeal = Nothing,
          tlFloatText = "",
          tlText = txt
        }

-- Timing helpers (1:1 port of battleTiming.ts)

visualTimeAt :: ResolvedTimeline -> Double -> Double
visualTimeAt tl t =
  case find (\h -> t >= rhAtMs h && t < rhAtMs h + rhHitStopMs h) (tlHits tl) of
    Just h -> rhAtMs h
    Nothing -> t

hitIndexAt :: ResolvedTimeline -> Double -> Int
hitIndexAt tl t =
  foldl' (\acc (i, h) -> if t >= rhAtMs h then i else acc) (-1) (zip [0 ..] (tlHits tl))

poseKeyAt :: [PoseKey] -> Double -> Maybe PoseKey
poseKeyAt keys t =
  foldl' (\acc k -> if t >= pkAtMs k then Just k else acc) Nothing keys

reachPointAt :: ResolvedTimeline -> Double -> PinPoint
reachPointAt tl t =
  let keys = raPoseKeys (tlActor tl)
   in case poseKeyAt keys t >>= pkPin of
        Just p -> p
        Nothing ->
          case find (\k -> pkAtMs k > t && isJust (pkPin k)) keys >>= pkPin of
            Just p -> p
            Nothing ->
              fromMaybe PinHand (find (isJust . pkPin) (reverse keys) >>= pkPin)

reactionStartAt :: ResolvedTimeline -> ResolvedHit -> Double
reactionStartAt tl hit =
  let launch = raActionDelayMs (tlActor tl)
   in case rhReaction hit of
        ReactDodge -> max launch (rhAtMs hit - rlLeadMs (spReactDodge (rhStaging hit)))
        ReactParry -> max launch (rhAtMs hit - rlLeadMs (spReactParry (rhStaging hit)))
        _ -> rhAtMs hit

activeReactionAt :: ResolvedTimeline -> Double -> Maybe (ResolvedHit, Int, Double)
activeReactionAt tl t =
  foldl' step Nothing (zip [0 ..] (tlHits tl))
  where
    step acc (idx, hit) =
      let sAt = reactionStartAt tl hit
       in if t < sAt
            then acc
            else case acc of
              Just (prevHit, prevIdx, prevStart)
                | prevIdx == idx - 1 && rhReaction prevHit == rhReaction hit ->
                    Just (hit, idx, prevStart)
              _ -> Just (hit, idx, sAt)

hitForPinnedKey :: ResolvedTimeline -> PoseKey -> ResolvedHit
hitForPinnedKey tl key =
  let pinned = filter (isJust . pkPin) (raPoseKeys (tlActor tl))
      idx = fromMaybe 0 (elemIndex key pinned)
      hs = tlHits tl
   in hs !! max 0 (min idx (length hs - 1))

easeOut :: Double -> Double
easeOut v = 1.0 - (1.0 - v) ** 3.0

actorOffsetAt :: ResolvedTimeline -> Double -> (Double, Double, Double)
actorOffsetAt tl t =
  let keys = raOffsetKeys (tlActor tl)
   in case keys of
        [] -> (0, 0, 0)
        (k0 : _)
          | t < okAtMs k0 -> (0, 0, 0)
          | otherwise ->
              let idx = foldl' (\acc (i, k) -> if t >= okAtMs k then i else acc) 0 (zip [0 ..] keys)
                  fromK = keys !! idx
                  (fx, fy, fa) = (okX fromK, okY fromK, okAngle fromK)
               in if idx + 1 >= length keys
                    then (fx, fy, fa)
                    else
                      let nextK = keys !! (idx + 1)
                       in case okEase nextK of
                            EaseCut -> (fx, fy, fa)
                            ez ->
                              let raw = max 0.0 (min 1.0 ((t - okAtMs fromK) / max 1.0 (okAtMs nextK - okAtMs fromK)))
                                  p = if ez == EaseOut then easeOut raw else raw
                               in ( fx + (okX nextK - fx) * p,
                                    fy + (okY nextK - fy) * p,
                                    fa + (okAngle nextK - fa) * p
                                  )

-- Exact Pose Sampler with IK pinning (1:1 port of svgBattlePose.ts)

sampleSvgPose ::
  PoseLibrary ->
  Maybe ResolvedTimeline ->
  BattleSide ->
  Double ->
  CombatStyle ->
  Text ->
  Bool ->
  SvgPose
sampleSvgPose lib mTl side elapsed style frameId reduced =
  let idleP = svgPose lib "idle" style
   in case mTl of
        Nothing -> idleP
        Just tl
          | tlKind tl == "settlement" || tlKind tl == "effect_tick" -> idleP
          | reduced ->
              let arrival = raActionDelayMs (tlActor tl)
               in if side == raSide (tlActor tl) && elapsed < arrival
                    then idleP
                    else svgPose lib frameId style
          | otherwise ->
              let c = tlChoreography tl
                  arrival = raActionDelayMs (tlActor tl)
                  t = visualTimeAt tl elapsed
               in if side /= raSide (tlActor tl)
                    then case activeReactionAt tl t of
                      Nothing -> idleP
                      Just (hit, _, _)
                        | rhReaction hit == ReactNone || rhReaction hit == ReactEffect -> idleP
                        | t >= chRestAtMs c -> idleP
                        | otherwise ->
                            let look = case rhReaction hit of
                                  ReactDodge -> spReactDodge (rhStaging hit)
                                  ReactParry -> spReactParry (rhStaging hit)
                                  _ -> spReactHit (rhStaging hit)
                                fallbackFrame = case avFrames (rhTargetVisual hit) of
                                  (f : _) -> fhFrameId f
                                  [] -> "hurt"
                             in svgPose lib (fromMaybe fallbackFrame (rlPose look)) style
                    else
                      if raMotion (tlActor tl) == "focus"
                        then
                          if t < chLaunchAtMs c || t >= chRestAtMs c
                            then idleP
                            else
                              let fPose = fromMaybe "guard" (avKeyPoses (raVisual (tlActor tl)) >>= kpContact)
                               in svgPose lib fPose style
                        else
                          let keys = raPoseKeys (tlActor tl)
                           in if null keys
                                then svgPose lib frameId style
                                else
                                  if t < arrival && isJust (raApproach (tlActor tl))
                                    then svgPose lib (maybe "approach" apPose (raApproach (tlActor tl))) style
                                    else keyedPose lib (fromMaybe (head keys) (poseKeyAt keys t)) tl style t

keyedPose :: PoseLibrary -> PoseKey -> ResolvedTimeline -> CombatStyle -> Double -> SvgPose
keyedPose lib key tl style t =
  let pose = svgPose lib (pkPose key) style
   in case pkPin key of
        Nothing -> pose
        Just pin ->
          let c = tlChoreography tl
              hit = hitForPinnedKey tl key
              (ox, oy, _) = actorOffsetAt tl t
              standoff = if rhResult hit == ResParry then rlStandoff (spReactParry (rhStaging hit)) else 0.0
              reachX = fromMaybe (chReach c) (pkReach key) - standoff - ox
              targetY = fromMaybe (chContactY c) (pkContactY key) - 176.0 - oy
           in case pin of
                PinFoot -> reachWith pose False (reachX, targetY)
                PinHand -> reachWith pose True (reachX, targetY)
                PinBlade ->
                  let (hx, hy) = spHand pose
                      dy = targetY - hy
                   in if abs dy < svgSwordLength - 0.5
                        then
                          let dx = sqrt (svgSwordLength * svgSwordLength - dy * dy)
                              shifted = shiftPose pose (reachX - dx - hx) 0.0
                           in shifted {spBlade = atan2 dy dx * 180.0 / pi}
                        else
                          let rad = spBlade pose * pi / 180.0
                           in reachWith pose True (reachX - cos rad * svgSwordLength, targetY - sin rad * svgSwordLength)

-- Deterministic Stage Director (1:1 port of battleDirector.ts)

clamp01 :: Double -> Double
clamp01 v = max 0.0 (min 1.0 v)

prog :: Double -> Double -> Double -> Double
prog t a b = clamp01 ((t - a) / max 1.0 (b - a))

smooth01 :: Double -> Double
smooth01 v = v * v * (3.0 - 2.0 * v)

dashIn :: Double -> Double
dashIn p = let u = clamp01 p in 1.0 - (1.0 - u) * (1.0 - u)

dashOut :: Double -> Double
dashOut p = smooth01 (clamp01 p)

sampleBattleScene ::
  Maybe ResolvedTimeline ->
  Double ->
  ActorVisual ->
  ActorVisual ->
  Bool ->
  SceneSample
sampleBattleScene mTl elapsedMs idleP idleE reducedMotion =
  let mkIdle vis =
        let fid = case avFrames vis of (f : _) -> fhFrameId f; [] -> "idle"
         in FigureSample vis fid 0 0 0 1 0
      base =
        SceneSample
          { scPlayer = mkIdle idleP,
            scEnemy = mkIdle idleE,
            scPhase = "idle",
            scCameraScale = 1.0,
            scCameraX = 0.0,
            scShakeY = 0.0,
            scShade = 0.0,
            scTrail = 0.0,
            scBurst = 0.0,
            scGuard = 0.0,
            scAura = 0.0,
            scGhost = 0.0,
            scInvert = 0.0,
            scAngle = 0.0,
            scTextAlpha = 0.0,
            scTextLift = 0.0,
            scTextScale = 1.0,
            scContact = (0.0, -70.0),
            scForce = 0.0,
            scHitIndex = -1,
            scResultAlpha = 0.0
          }
   in case mTl of
        Nothing -> base
        Just tl ->
          let t = max 0.0 (min elapsedMs (tlDurationMs tl))
           in if tlKind tl == "settlement"
                then
                  let rAlpha = easeOut (prog t 0 180) * (1.0 - prog t (tlDurationMs tl - 160) (tlDurationMs tl))
                      fadeAmt = if reducedMotion then 0.0 else easeOut (prog t 80 480)
                      modLoser fig = fig {fsAlpha = 1.0 - fadeAmt * 0.7, fsY = fadeAmt * 5.0}
                      (pl', en') =
                        if rtSide (tlTarget tl) == SidePlayer
                          then (modLoser (scPlayer base), scEnemy base)
                          else (scPlayer base, modLoser (scEnemy base))
                   in base
                        { scPlayer = pl',
                          scEnemy = en',
                          scPhase = "settlement",
                          scShade = rAlpha * 0.38,
                          scResultAlpha = rAlpha
                        }
                else
                  let c = tlChoreography tl
                      stg = tlStaging tl
                      arrival = raActionDelayMs (tlActor tl)
                      impact = tlImpactAtMs tl
                      holdEnd = impact + chHitStopMs c
                      vTime = visualTimeAt tl t
                      hIdx = hitIndexAt tl t
                      curHit = tlHits tl !! max 0 hIdx
                      hitHoldEnd = rhAtMs curHit + rhHitStopMs curHit
                      finalHit = last (tlHits tl)
                      actorIsPlayer = raSide (tlActor tl) == SidePlayer
                      targetIsPlayer = rtSide (tlTarget tl) == SidePlayer
                      dir = if actorIsPlayer then 1.0 else -1.0
                      tDir = if targetIsPlayer then -1.0 else 1.0
                      attack = isTravelMotion (raMotion (tlActor tl))
                      strikes = attack || raMotion (tlActor tl) == "ranged"
                      quiet = tlKind tl == "effect_tick"
                      retreat = prog vTime (chRecoverAtMs c) (chRestAtMs c)
                      recovery = smooth01 retreat
                      envelope = if quiet then 0.0 else easeOut (prog vTime 0 (max 1.0 (chLaunchAtMs c))) * (1.0 - recovery)
                      phaseTxt
                        | t < arrival = "approach"
                        | t < chLaunchAtMs c = "prepare"
                        | t < impact = "strike"
                        | t < chRecoverAtMs c = "impact"
                        | t < chRestAtMs c = "recover"
                        | otherwise = "idle"

                      -- Actor figure
                      actorInit = if actorIsPlayer then scPlayer base else scEnemy base
                      actorVis = if quiet then fsVisual actorInit else raVisual (tlActor tl)
                      actorFrame
                        | quiet = fsFrameId actorInit
                        | t < arrival, Just ap <- raApproach (tlActor tl) = apPose ap
                        | otherwise = clipFrameAt (avFrames actorVis) (max 0.0 (vTime - arrival)) (tlDurationMs tl - arrival)
                      (dashX, dashY) =
                        if attack
                          then
                            let travel = max 8.0 (sideHome SideEnemy - sideHome SidePlayer - chReach c)
                                d = prog vTime 0 arrival
                                liftH = maybe 0.0 apLift (raApproach (tlActor tl))
                                arc p = if p <= 0 || p >= 1 then 0.0 else sin (pi * p)
                             in ( dir * travel * dashIn d * (1.0 - dashOut retreat),
                                  -liftH * arc d - liftH * 0.6 * arc retreat
                                )
                          else (0.0, 0.0)
                      (offX, offY, offAng) =
                        if not quiet && not (null (raOffsetKeys (tlActor tl)))
                          then actorOffsetAt tl vTime
                          else (0.0, 0.0, 0.0)
                      actorFig =
                        actorInit
                          { fsVisual = actorVis,
                            fsFrameId = actorFrame,
                            fsX = dashX + dir * offX,
                            fsY = dashY + offY,
                            fsAngle = dir * offAng
                          }

                      -- Target figure & dodge ghost
                      targetInit = if targetIsPlayer then scPlayer base else scEnemy base
                      (targetMoved, ghostVal) =
                        if quiet || actorIsPlayer == targetIsPlayer
                          then (targetInit, 0.0)
                          else case activeReactionAt tl t of
                            Just (rHit, _, startAt)
                              | t < chRestAtMs c && rhReaction rHit /= ReactNone && rhReaction rHit /= ReactEffect ->
                                  let rxn = rhReaction rHit
                                      look = case rxn of
                                        ReactDodge -> spReactDodge (rhStaging rHit)
                                        ReactParry -> spReactParry (rhStaging rHit)
                                        _ -> spReactHit (rhStaging rHit)
                                      tVis = rhTargetVisual rHit
                                      tFid = case avFrames tVis of (f : _) -> fhFrameId f; [] -> "hurt"
                                      rTime =
                                        if rxn == ReactHit
                                          then rhAtMs rHit + max 0.0 (t - rhAtMs rHit - rhHitStopMs rHit)
                                          else vTime
                                      onset =
                                        if rxn == ReactHit
                                          then 1.0
                                          else easeOut (prog rTime startAt (startAt + rlOnsetMs look))
                                      amount = onset * (1.0 - recovery)
                                      rHoldEnd = rhAtMs rHit + rhHitStopMs rHit
                                      stagger =
                                        if rxn == ReactHit
                                          then rlSnap look + (1.0 - rlSnap look) * easeOut (prog t rHoldEnd (rHoldEnd + 200.0))
                                          else 1.0
                                      tx = tDir * rlPush look * amount * stagger
                                      ty
                                        | rxn == ReactHit && rlLift look > 0 = -rlLift look * amount
                                        | rxn == ReactDodge && rlHop look > 0 =
                                            let jmp = prog vTime startAt (startAt + 300.0)
                                             in if jmp > 0 && jmp < 1 then -rlHop look * sin (pi * jmp) * (1.0 - recovery) else 0.0
                                        | otherwise = 0.0
                                      tang = tDir * (if rxn == ReactHit then rlTilt look else 0.0) * amount
                                      gh = if rxn == ReactDodge then rlGhost look * amount else 0.0
                                   in (targetInit {fsVisual = tVis, fsFrameId = tFid, fsX = tx, fsY = ty, fsAngle = tang}, gh)
                            _ -> (targetInit, 0.0)

                      -- Post-impact feedback, flash, camera kick, text callout
                      (tAlpha, tLift, tScale, burstV, guardV, auraV, tFlash, camX, shkY) =
                        if t < impact
                          then (0, 0, 1, 0, 0, 0, 0, 0, 0)
                          else
                            let fbTime = if vTime == rhAtMs curHit then 0.0 else vTime - hitHoldEnd
                                fall = min (spFallMs (rhStaging curHit)) (max 1.0 (tlDurationMs tl - hitHoldEnd))
                                fb = 1.0 - easeOut (clamp01 ((vTime - hitHoldEnd) / max 1.0 fall))
                                textEnd = min (tlDurationMs tl) (max (rhAtMs finalHit + 340.0) (chRestAtMs c))
                                ta = 1.0 - smooth01 (prog t (max (rhAtMs finalHit + 190.0) (textEnd - 190.0)) textEnd)
                                tlft = 26.0 * easeOut (prog vTime holdEnd textEnd)
                                tsc = 0.84 + 0.16 * easeOut (prog vTime (rhAtMs curHit) (rhAtMs curHit + 120.0))
                                bv = if rhResult curHit == ResHit then fb else 0.0
                                fl = if rhResult curHit == ResHit then fb * spFlash (rhStaging curHit) else 0.0
                                gv = if rhResult curHit == ResParry then fb else 0.0
                                av = if isJust (tlHeal tl) || raMotion (tlActor tl) == "focus" then (1.0 - recovery) * 0.65 else 0.0
                                cam = spCamera (rhStaging curHit)
                                dec = fb * fb
                                cx =
                                  if not quiet && not reducedMotion
                                    then
                                      dir * csKick cam * dec * cos (max 0.0 fbTime * 0.045)
                                        + dir * csKick cam * dec * cos (max 0.0 fbTime * 0.11) * csRebound cam
                                    else 0.0
                                sy =
                                  if not quiet && not reducedMotion
                                    then -csKick cam * csLift cam * dec * cos (max 0.0 fbTime * 0.05)
                                    else 0.0
                             in (ta, tlft, tsc, bv, gv, av, fl, cx, sy)

                      targetFinal = targetMoved {fsFlash = tFlash}
                      (plFig, enFig)
                        | actorIsPlayer && targetIsPlayer = (actorFig {fsFlash = tFlash}, scEnemy base)
                        | not actorIsPlayer && not targetIsPlayer = (scPlayer base, actorFig {fsFlash = tFlash})
                        | actorIsPlayer = (actorFig, targetFinal)
                        | otherwise = (targetFinal, actorFig)

                      leadMs = tsLeadMs (spTrail stg)
                      fadeMs = tsFadeMs (spTrail stg)
                      trailV =
                        if not attack
                          then 0.0
                          else case find (\h -> t >= rhAtMs h - leadMs && t < rhAtMs h + rhHitStopMs h + fadeMs) (reverse (tlHits tl)) of
                            Nothing -> 0.0
                            Just th ->
                              let endT = rhAtMs th + rhHitStopMs th
                               in if t < rhAtMs th
                                    then prog t (rhAtMs th - leadMs) (rhAtMs th)
                                    else 1.0 - easeOut (prog vTime endT (endT + fadeMs))

                      invertV =
                        if not quiet && not reducedMotion && any (\h -> rhHitStopMs h > 0 && t >= rhAtMs h && t < rhAtMs h + rhHitStopMs h) (tlHits tl)
                          then 1.0
                          else 0.0
                      stageAng =
                        if quiet || t >= chRestAtMs c
                          then 0.0
                          else spTilt stg * sin (pi * prog t 0 (max 1.0 (chRestAtMs c)))
                      cutIn = if quiet then 0.0 else prog vTime (chLaunchAtMs c) impact
                      camScale = 1.0 + (if cutIn >= 1.0 then 1.0 else envelope * 0.35) * csZoom (spCamera stg)
                      shadeV = envelope * spShade stg + invertV * 0.25

                      rawSample =
                        SceneSample
                          { scPlayer = plFig,
                            scEnemy = enFig,
                            scPhase = phaseTxt,
                            scCameraScale = camScale,
                            scCameraX = camX,
                            scShakeY = shkY,
                            scShade = shadeV,
                            scTrail = trailV,
                            scBurst = burstV,
                            scGuard = guardV,
                            scAura = auraV,
                            scGhost = ghostVal,
                            scInvert = invertV,
                            scAngle = stageAng,
                            scTextAlpha = tAlpha,
                            scTextLift = tLift,
                            scTextScale = tScale,
                            scContact = (sideHome (rtSide (tlTarget tl)), if strikes then chContactY c - 176.0 else -70.0),
                            scForce = if quiet || not strikes then 0.0 else spForce stg,
                            scHitIndex = hIdx,
                            scResultAlpha = 0.0
                          }
                   in if reducedMotion
                        then
                          let zeroMove f = f {fsX = 0, fsY = 0, fsAngle = 0}
                           in rawSample
                                { scPlayer = zeroMove (scPlayer rawSample),
                                  scEnemy = zeroMove (scEnemy rawSample),
                                  scCameraScale = 1.0,
                                  scCameraX = 0.0,
                                  scShakeY = 0.0,
                                  scAngle = 0.0,
                                  scTrail = 0.0,
                                  scGhost = 0.0,
                                  scTextLift = 0.0,
                                  scInvert = 0.0,
                                  scTextScale = 1.0,
                                  scBurst = scBurst rawSample * 0.4
                                }
                        else rawSample

spawnHitParticles :: Pt -> BattleSide -> CombatResult -> Double -> Int -> [InkParticle]
spawnHitParticles (ix, iy) actorSide res force seed0 =
  let dir = if actorSide == SidePlayer then 1.0 else -1.0 :: Double
      isHeavy = force >= 0.85
      count = case res of
        ResDodge -> 6 :: Int
        ResParry -> 16
        ResEffect -> 10
        ResHit -> if isHeavy then 26 else 16
      mk i =
        let h1 = fromIntegral ((seed0 * 1103515245 + i * 7919 + 12345) `mod` 1000) / 1000.0
            h2 = fromIntegral ((seed0 * 48271 + i * 104729 + 54321) `mod` 1000) / 1000.0
            ang = (-0.9 + h1 * 1.8) + (if dir > 0 then 0.0 else pi)
            spd = 85.0 + h2 * (if isHeavy then 280.0 else 185.0)
            col = case res of
              ResParry -> if i `mod` 2 == 0 then "#b37c24" else "#d9a94e"
              ResDodge -> "#2b594b"
              ResEffect -> "#386944"
              ResHit ->
                if i `mod` 4 == 0
                  then "#a32c22"
                  else if i `mod` 3 == 0 then "#4a4035" else "#1e1a16"
         in InkParticle
              { ipX = ix,
                ipY = iy + (h1 - 0.5) * 16.0,
                ipVx = cos ang * spd,
                ipVy = sin ang * spd - 45.0,
                ipRadius = 2.0 + h2 * (if isHeavy then 4.8 else 3.4),
                ipLife = 0.0,
                ipMaxLife = 0.30 + h1 * 0.34,
                ipColor = col
              }
   in [mk i | i <- [1 .. count]]
