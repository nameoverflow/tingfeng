{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Tingfeng.Pose
  ( Pt,
    HandShape (..),
    CombatStyle (..),
    combatStyleText,
    parseCombatStyle,
    VisualProfile (..),
    visualProfileText,
    parseVisualProfile,
    LookStyle (..),
    Bones (..),
    PoseParams (..),
    SvgPose (..),
    PoseLibrary (..),
    ShapePrim (..),
    JoinPatch (..),
    ActorPart (..),
    svgSwordLength,
    parsePoseLibrary,
    allPoseIds,
    svgPose,
    blendPose,
    shiftPose,
    reachWith,
    swordTipOf,
    buildActorParts,
  )
where

import Data.Fixed (mod')
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Tingfeng.Json

type Pt = (Double, Double)

data HandShape = HandFist | HandPalm | HandFinger
  deriving (Show, Eq)

data CombatStyle = StyleFist | StyleSword
  deriving (Show, Eq, Ord)

combatStyleText :: CombatStyle -> Text
combatStyleText StyleFist = "fist"
combatStyleText StyleSword = "sword"

parseCombatStyle :: Text -> CombatStyle
parseCombatStyle "sword" = StyleSword
parseCombatStyle _ = StyleFist

data VisualProfile = ProfileMale | ProfileFemale
  deriving (Show, Eq)

visualProfileText :: VisualProfile -> Text
visualProfileText ProfileMale = "male"
visualProfileText ProfileFemale = "female"

parseVisualProfile :: Text -> VisualProfile
parseVisualProfile "female" = ProfileFemale
parseVisualProfile _ = ProfileMale

data LookStyle = LookMaiden | LookPonytail
  deriving (Show, Eq)

data Bones = Bones
  { bTorso :: !Double,
    bNeck :: !Double,
    bHeadRadius :: !Double,
    bUpperArm :: !Double,
    bForearm :: !Double,
    bThigh :: !Double,
    bShin :: !Double
  }
  deriving (Show, Eq)

data PoseParams = PoseParams
  { ppHip :: !Pt,
    ppTorso :: !Double,
    ppHead :: !Double,
    ppArm :: !(Double, Double),
    ppBackArm :: !(Double, Double),
    ppFoot :: !Pt,
    ppBackFoot :: !Pt,
    ppKnees :: !(Double, Double),
    ppBlade :: !Double,
    ppTassel :: !Pt,
    ppHands :: !(HandShape, HandShape)
  }
  deriving (Show, Eq)

data PartialParams = PartialParams
  { pmHip :: !(Maybe Pt),
    pmTorso :: !(Maybe Double),
    pmHead :: !(Maybe Double),
    pmArm :: !(Maybe (Double, Double)),
    pmBackArm :: !(Maybe (Double, Double)),
    pmFoot :: !(Maybe Pt),
    pmBackFoot :: !(Maybe Pt),
    pmKnees :: !(Maybe (Double, Double)),
    pmBlade :: !(Maybe Double),
    pmTassel :: !(Maybe Pt),
    pmHands :: !(Maybe (HandShape, HandShape))
  }
  deriving (Show, Eq)

emptyPartial :: PartialParams
emptyPartial =
  PartialParams Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

applyPartial :: PartialParams -> PoseParams -> PoseParams
applyPartial p base =
  PoseParams
    { ppHip = fromMaybe (ppHip base) (pmHip p),
      ppTorso = fromMaybe (ppTorso base) (pmTorso p),
      ppHead = fromMaybe (ppHead base) (pmHead p),
      ppArm = fromMaybe (ppArm base) (pmArm p),
      ppBackArm = fromMaybe (ppBackArm base) (pmBackArm p),
      ppFoot = fromMaybe (ppFoot base) (pmFoot p),
      ppBackFoot = fromMaybe (ppBackFoot base) (pmBackFoot p),
      ppKnees = fromMaybe (ppKnees base) (pmKnees p),
      ppBlade = fromMaybe (ppBlade base) (pmBlade p),
      ppTassel = fromMaybe (ppTassel base) (pmTassel p),
      ppHands = fromMaybe (ppHands base) (pmHands p)
    }

data PoseDef = PoseDef
  { pdExtends :: !(Maybe Text),
    pdBlend :: !(Maybe (Text, Text, Double)),
    pdSet :: !PartialParams,
    pdRigs :: !(M.Map CombatStyle PartialParams)
  }
  deriving (Show, Eq)

data PoseLibrary = PoseLibrary
  { plBones :: !Bones,
    plPoseOrder :: ![Text],
    plResolved :: !(M.Map (CombatStyle, Text) PoseParams)
  }
  deriving (Show, Eq)

allPoseIds :: PoseLibrary -> [Text]
allPoseIds = plPoseOrder

data SvgPose = SvgPose
  { spNeck :: !Pt,
    spHead :: !Pt,
    spShoulder :: !Pt,
    spHip :: !Pt,
    spBackElbow :: !Pt,
    spBackHand :: !Pt,
    spElbow :: !Pt,
    spHand :: !Pt,
    spBackKnee :: !Pt,
    spBackFoot :: !Pt,
    spKnee :: !Pt,
    spFoot :: !Pt,
    spTassel :: !Pt,
    spBlade :: !Double,
    spFootPlanted :: !Bool,
    spBackFootPlanted :: !Bool,
    spHands :: !(HandShape, HandShape),
    spBones :: !Bones
  }
  deriving (Show, Eq)

data ShapePrim
  = SCircle !Double !Double !Double !(Maybe Text) !Double
  | SPoly ![Pt] !(Maybe Text) !Double
  deriving (Show, Eq)

data JoinPatch = JoinPatch
  { jpAt :: !Pt,
    jpRadius :: !Double,
    jpShapes :: ![ShapePrim]
  }
  deriving (Show, Eq)

data ActorPart = ActorPart
  { apKey :: !Text,
    apShapes :: ![ShapePrim],
    apJoins :: ![JoinPatch]
  }
  deriving (Show, Eq)

svgSwordLength :: Double
svgSwordLength = 72.0

ankleHeight :: Double
ankleHeight = 5.0

shoulderDrop :: Double
shoulderDrop = 8.0

degToRad :: Double -> Double
degToRad d = d * pi / 180.0

dirVec :: Double -> Pt
dirVec deg = let r = degToRad deg in (cos r, sin r)

ptAdd :: Pt -> Pt -> Double -> Pt
ptAdd (ax, ay) (bx, by) k = (ax + bx * k, ay + by * k)

ptSub :: Pt -> Pt -> Pt
ptSub (ax, ay) (bx, by) = (ax - bx, ay - by)

ptLen :: Pt -> Double
ptLen (x, y) = let d = sqrt (x * x + y * y) in if d < 1e-6 then 1.0 else d

ptUnit :: Pt -> Pt
ptUnit v@(x, y) = let l = ptLen v in (x / l, y / l)

ptRot :: Pt -> Double -> Pt
ptRot (x, y) deg =
  let r = degToRad deg
      c = cos r
      s = sin r
   in (x * c - y * s, x * s + y * c)

lerp :: Double -> Double -> Double -> Double
lerp a b t = a + (b - a) * t

lerpAngle :: Double -> Double -> Double -> Double
lerpAngle a b t =
  let diff = ((b - a + 540.0) `mod'` 360.0) - 180.0
   in a + diff * t

blendParams :: PoseParams -> PoseParams -> Double -> PoseParams
blendParams a b amt
  | amt <= 0 = a
  | amt >= 1 = b
  | otherwise =
      let pt (x1, y1) (x2, y2) = (lerp x1 x2 amt, lerp y1 y2 amt)
          angPair (u1, f1) (u2, f2) = (lerpAngle u1 u2 amt, lerpAngle f1 f2 amt)
       in PoseParams
            { ppHip = pt (ppHip a) (ppHip b),
              ppTorso = lerpAngle (ppTorso a) (ppTorso b) amt,
              ppHead = lerpAngle (ppHead a) (ppHead b) amt,
              ppArm = angPair (ppArm a) (ppArm b),
              ppBackArm = angPair (ppBackArm a) (ppBackArm b),
              ppFoot = pt (ppFoot a) (ppFoot b),
              ppBackFoot = pt (ppBackFoot a) (ppBackFoot b),
              ppKnees = if amt < 0.5 then ppKnees a else ppKnees b,
              ppBlade = lerpAngle (ppBlade a) (ppBlade b) amt,
              ppTassel = pt (ppTassel a) (ppTassel b),
              ppHands = if amt < 0.5 then ppHands a else ppHands b
            }

solveTwoBone :: Pt -> Pt -> Double -> Double -> Double -> (Pt, Pt)
solveTwoBone (rx, ry) (tx, ty) a b bend =
  let dx = tx - rx
      dy = ty - ry
      rawD = sqrt (dx * dx + dy * dy)
      d = max (abs (a - b) + 0.01) (min (a + b - 0.01) rawD)
      theta = atan2 dy dx
      cosAlpha = max (-1.0) (min 1.0 ((a * a + d * d - b * b) / (2.0 * a * d)))
      alpha = acos cosAlpha
      sgn = if bend < 0 then -1.0 else 1.0
      jointAng = theta - sgn * alpha
      joint = (rx + cos jointAng * a, ry + sin jointAng * a)
      endPt = (rx + cos theta * d, ry + sin theta * d)
   in (joint, endPt)

bendOf :: Pt -> Pt -> Pt -> Double
bendOf (rx, ry) (jx, jy) (ex, ey) =
  let cross = (ex - rx) * (jy - ry) - (ey - ry) * (jx - rx)
   in if cross < 0 then 1.0 else -1.0

isPlanted :: Pt -> Bool
isPlanted (_, fy) = fy > -4.0

ankleOf :: Pt -> Pt
ankleOf f@(fx, fy) = if isPlanted f then (fx, fy - ankleHeight) else f

poseFromParams :: Bones -> PoseParams -> SvgPose
poseFromParams b params =
  let reach = bThigh b + bShin b - 0.5
      frontAnkle = ankleOf (ppFoot params)
      backAnkle = ankleOf (ppBackFoot params)
      sinkHip (hx, hy) (fx, fy) =
        let dx = fx - hx
         in if abs dx < reach
              then (hx, max hy (fy - sqrt (reach * reach - dx * dx)))
              else (hx, hy)
      hip = sinkHip (sinkHip (ppHip params) frontAnkle) backAnkle
      neck = ptAdd hip (dirVec (ppTorso params)) (bTorso b)
      shoulder = ptAdd neck (dirVec (ppTorso params)) (-shoulderDrop)
      headPt = ptAdd neck (dirVec (ppHead params)) (bNeck b + bHeadRadius b)
      (armU, armF) = ppArm params
      (bArmU, bArmF) = ppBackArm params
      elbow = ptAdd shoulder (dirVec armU) (bUpperArm b)
      handPt = ptAdd elbow (dirVec armF) (bForearm b)
      backElbow = ptAdd shoulder (dirVec bArmU) (bUpperArm b)
      backHand = ptAdd backElbow (dirVec bArmF) (bForearm b)
      (kFront, kBack) = ppKnees params
      (frontKnee, frontEnd) = solveTwoBone hip frontAnkle (bThigh b) (bShin b) kFront
      (backKnee, backEnd) = solveTwoBone hip backAnkle (bThigh b) (bShin b) kBack
   in SvgPose
        { spNeck = neck,
          spHead = headPt,
          spShoulder = shoulder,
          spHip = hip,
          spBackElbow = backElbow,
          spBackHand = backHand,
          spElbow = elbow,
          spHand = handPt,
          spBackKnee = backKnee,
          spBackFoot = backEnd,
          spKnee = frontKnee,
          spFoot = frontEnd,
          spTassel = ppTassel params,
          spBlade = ppBlade params,
          spFootPlanted = isPlanted (ppFoot params),
          spBackFootPlanted = isPlanted (ppBackFoot params),
          spHands = ppHands params,
          spBones = b
        }

parsePoseLibrary :: Text -> Either String PoseLibrary
parsePoseLibrary raw = do
  root <- parseJson raw
  mp <- case root of
    JObj m -> Right m
    _ -> Left "svg-poses.json root is not an object"
  bonesVal <- maybe (Left "Missing bones") Right (M.lookup "bones" mp)
  bones <- decodeBones bonesVal
  baseVal <- maybe (Left "Missing base") Right (M.lookup "base" mp)
  basePart <- decodePartial baseVal
  let baseParams = applyPartial basePart defaultBaseParams
  rigsMap <- case M.lookup "rigs" mp of
    Just (JObj rm) -> do
      fistP <- maybe (Right emptyPartial) decodePartial (M.lookup "fist" rm)
      swordP <- maybe (Right emptyPartial) decodePartial (M.lookup "sword" rm)
      Right (M.fromList [(StyleFist, fistP), (StyleSword, swordP)])
    _ -> Right M.empty
  posesDefs <- case M.lookup "poses" mp of
    Just (JObj pm) -> traverse decodePoseDef pm
    _ -> Left "Missing poses map"
  let resolveOne rig pid trail =
        if pid `elem` trail
          then baseParams
          else case M.lookup pid posesDefs of
            Nothing -> applyPartial (M.findWithDefault emptyPartial rig rigsMap) baseParams
            Just def ->
              let nextTrail = pid : trail
                  start = case pdBlend def of
                    Just (fId, tId, amt) ->
                      blendParams (resolveOne rig fId nextTrail) (resolveOne rig tId nextTrail) amt
                    Nothing -> case pdExtends def of
                      Just extId -> resolveOne rig extId nextTrail
                      Nothing -> applyPartial (M.findWithDefault emptyPartial rig rigsMap) baseParams
                  withSet = applyPartial (pdSet def) start
               in applyPartial (M.findWithDefault emptyPartial rig (pdRigs def)) withSet
      allResolved =
        M.fromList
          [ ((rig, pid), resolveOne rig pid [])
            | rig <- [StyleFist, StyleSword],
              pid <- M.keys posesDefs
          ]
  Right (PoseLibrary bones (M.keys posesDefs) allResolved)
  where
    defaultBaseParams =
      PoseParams (-4, -56) (-84) (-86) (30, -20) (62, -22) (26, 0) (-30, 0) (1, 1) (-40) (-20, -10) (HandFist, HandFist)

    decodeBones (JObj m) =
      Right $
        Bones
          (jFieldDef 42 jDouble "torso" m)
          (jFieldDef (-1) jDouble "neck" m)
          (jFieldDef 15 jDouble "headRadius" m)
          (jFieldDef 26 jDouble "upperArm" m)
          (jFieldDef 24 jDouble "forearm" m)
          (jFieldDef 34 jDouble "thigh" m)
          (jFieldDef 33 jDouble "shin" m)
    decodeBones _ = Left "Invalid bones object"

    decodePair dec (JArr [a, b]) = (,) <$> dec a <*> dec b
    decodePair _ _ = Nothing

    decodeHand (JStr "palm") = Just HandPalm
    decodeHand (JStr "finger") = Just HandFinger
    decodeHand (JStr _) = Just HandFist
    decodeHand _ = Nothing

    decodePartial (JObj m) =
      Right $
        PartialParams
          { pmHip = jField (decodePair jDouble) "hip" m,
            pmTorso = jField jDouble "torso" m,
            pmHead = jField jDouble "head" m,
            pmArm = jField (decodePair jDouble) "arm" m,
            pmBackArm = jField (decodePair jDouble) "backArm" m,
            pmFoot = jField (decodePair jDouble) "foot" m,
            pmBackFoot = jField (decodePair jDouble) "backFoot" m,
            pmKnees = jField (decodePair jDouble) "knees" m,
            pmBlade = jField jDouble "blade" m,
            pmTassel = jField (decodePair jDouble) "tassel" m,
            pmHands = jField (decodePair decodeHand) "hands" m
          }
    decodePartial _ = Right emptyPartial

    decodePoseDef (JObj m) = do
      setP <- maybe (Right emptyPartial) decodePartial (M.lookup "set" m)
      rigsP <- case M.lookup "rigs" m of
        Just (JObj rm) -> do
          fP <- maybe (Right emptyPartial) decodePartial (M.lookup "fist" rm)
          sP <- maybe (Right emptyPartial) decodePartial (M.lookup "sword" rm)
          Right (M.fromList [(StyleFist, fP), (StyleSword, sP)])
        _ -> Right M.empty
      let blendSpec = case M.lookup "blend" m of
            Just (JObj bm) ->
              (,,)
                <$> jField jText "from" bm
                <*> jField jText "to" bm
                <*> jField jDouble "amount" bm
            _ -> Nothing
      Right
        PoseDef
          { pdExtends = jField jText "extends" m,
            pdBlend = blendSpec,
            pdSet = setP,
            pdRigs = rigsP
          }
    decodePoseDef _ = Right (PoseDef Nothing Nothing emptyPartial M.empty)

lookupParams :: PoseLibrary -> CombatStyle -> Text -> PoseParams
lookupParams lib rig pid =
  case M.lookup (rig, pid) (plResolved lib) of
    Just p -> p
    Nothing ->
      fromMaybe
        (PoseParams (-4, -56) (-84) (-86) (30, -20) (62, -22) (26, 0) (-30, 0) (1, 1) (-40) (-20, -10) (HandFist, HandFist))
        (M.lookup (rig, "idle") (plResolved lib))

svgPose :: PoseLibrary -> Text -> CombatStyle -> SvgPose
svgPose lib pid rig = poseFromParams (plBones lib) (lookupParams lib rig pid)

blendPose :: PoseLibrary -> Text -> Text -> Double -> CombatStyle -> SvgPose
blendPose lib fromId toId amt rig =
  poseFromParams (plBones lib) (blendParams (lookupParams lib rig fromId) (lookupParams lib rig toId) amt)

shiftPose :: SvgPose -> Double -> Double -> SvgPose
shiftPose p dx dy =
  let mv (x, y) = (x + dx, y + dy)
   in p
        { spNeck = mv (spNeck p),
          spHead = mv (spHead p),
          spShoulder = mv (spShoulder p),
          spHip = mv (spHip p),
          spElbow = mv (spElbow p),
          spHand = mv (spHand p),
          spBackElbow = mv (spBackElbow p),
          spBackHand = mv (spBackHand p),
          spKnee = mv (spKnee p),
          spFoot = mv (spFoot p),
          spBackKnee = mv (spBackKnee p),
          spBackFoot = mv (spBackFoot p),
          spTassel = mv (spTassel p)
        }

reachWith :: SvgPose -> Bool -> Pt -> SvgPose
reachWith pose isHand target@(tx, ty) =
  let b = spBones pose
      (root0, joint0, end0, lenA, lenB) =
        if isHand
          then (spShoulder pose, spElbow pose, spHand pose, bUpperArm b, bForearm b)
          else (spHip pose, spKnee pose, spFoot pose, bThigh b, bShin b)
      bend = bendOf root0 joint0 end0
      maxLen = lenA + lenB - 0.5
      (rx0, ry0) = root0
      dx = tx - rx0
      dy = ty - ry0
      dist = sqrt (dx * dx + dy * dy)
      shifted =
        if dist > maxLen && abs dy < maxLen
          then
            let sgn = if dx < 0 then -1.0 else 1.0
             in shiftPose pose (dx - sgn * sqrt (maxLen * maxLen - dy * dy)) 0
          else pose
      newRoot = if isHand then spShoulder shifted else spHip shifted
      (jSolved, eSolved) = solveTwoBone newRoot target lenA lenB bend
   in if isHand
        then shifted {spElbow = jSolved, spHand = eSolved}
        else shifted {spKnee = jSolved, spFoot = eSolved, spFootPlanted = False}

swordTipOf :: SvgPose -> Pt
swordTipOf p = ptAdd (spHand p) (dirVec (spBlade p)) svgSwordLength

smoothStep :: Double -> Double
smoothStep t = t * t * (3.0 - 2.0 * t)

sCircle :: Pt -> Double -> ShapePrim
sCircle (x, y) r = SCircle x y r Nothing 1.0

sPoly :: [Pt] -> ShapePrim
sPoly pts = SPoly pts Nothing 1.0

taperPts :: Pt -> Pt -> Double -> Double -> [Pt]
taperPts a b ra rb =
  let d@(dx, dy) = ptSub b a
      l = ptLen d
      (ux, uy) = (dx / l, dy / l)
      (nx, ny) = (-uy, ux)
      s = max (-0.95) (min 0.95 ((ra - rb) / l))
      c = sqrt (1.0 - s * s)
      m1 = (nx * c + ux * s, ny * c + uy * s)
      m2 = (-nx * c + ux * s, -ny * c + uy * s)
      onCircle (ox, oy) (mx, my) r = (ox + mx * r, oy + my * r)
   in [onCircle a m1 ra, onCircle b m1 rb, onCircle b m2 rb, onCircle a m2 ra]

closedCurvePts :: [Pt] -> [Pt]
closedCurvePts pts
  | length pts < 3 = pts
  | otherwise =
      let n = length pts
          at i = pts !! ((i + n) `mod` n)
          sampleSeg i =
            let (x0, y0) = at (i - 1)
                (x1, y1) = at i
                (x2, y2) = at (i + 1)
                (x3, y3) = at (i + 2)
                c1x = x1 + (x2 - x0) / 6.0
                c1y = y1 + (y2 - y0) / 6.0
                c2x = x2 - (x3 - x1) / 6.0
                c2y = y2 - (y3 - y1) / 6.0
                cubic t =
                  let u = 1.0 - t
                      u2 = u * u
                      t2 = t * t
                   in ( u2 * u * x1 + 3 * u2 * t * c1x + 3 * u * t2 * c2x + t2 * t * x2,
                        u2 * u * y1 + 3 * u2 * t * c1y + 3 * u * t2 * c2y + t2 * t * y2
                      )
             in [cubic (fromIntegral k / 6.0) | k <- [0 .. 5 :: Int]]
       in concatMap sampleSeg [0 .. n - 1]

ribbonPts :: [Pt] -> [Double] -> [Double] -> [Pt]
ribbonPts pts leftW rightW
  | length pts < 2 = pts
  | otherwise =
      let n = length pts
          atPt i = pts !! max 0 (min (n - 1) i)
          atL i = leftW !! max 0 (min (length leftW - 1) i)
          atR i = rightW !! max 0 (min (length rightW - 1) i)
          segSamples i =
            let (x0, y0) = atPt (i - 1)
                (x1, y1) = atPt i
                (x2, y2) = atPt (i + 1)
                (x3, y3) = atPt (i + 2)
                l0 = atL i
                l1 = atL (i + 1)
                r0 = atR i
                r1 = atR (i + 1)
                catmull q0 q1 q2 q3 t =
                  let t2 = t * t
                      t3 = t2 * t
                   in 0.5 * (2 * q1 + (q2 - q0) * t + (2 * q0 - 5 * q1 + 4 * q2 - q3) * t2 + (3 * q1 - q0 - 3 * q2 + q3) * t3)
             in [ let t = fromIntegral k / 8.0
                      e = smoothStep t
                   in ( (catmull x0 x1 x2 x3 t, catmull y0 y1 y2 y3 t),
                        l0 + (l1 - l0) * e,
                        r0 + (r1 - r0) * e
                      )
                  | k <- [0 .. 7 :: Int]
                ]
          samples = concatMap segSamples [0 .. n - 2] <> [(atPt (n - 1), atL (n - 1), atR (n - 1))]
          m = length samples
          centerAt j = let (p, _, _) = samples !! max 0 (min (m - 1) j) in p
          sides =
            [ let ((px, py), hl, hr) = samples !! idx
                  (dx, dy) = ptUnit (ptSub (centerAt (idx + 1)) (centerAt (idx - 1)))
               in ((px - dy * hl, py + dx * hl), (px + dy * hr, py - dx * hr))
              | idx <- [0 .. m - 1]
            ]
       in map fst sides <> reverse (map snd sides)

data LimbProfile = LimbProfile ![Double] ![Double] ![Double]

thighProf, shinProf, upperArmProf, forearmProf :: LimbProfile
thighProf = LimbProfile [0, 0.4, 1] [10.2, 9.4, 6.8] [10.2, 10.8, 6.8]
shinProf = LimbProfile [0, 0.32, 0.78, 1] [6.8, 8.1, 5.0, 4.1] [6.8, 6.4, 4.6, 4.1]
upperArmProf = LimbProfile [0, 0.35, 1] [8.2, 7.2, 5.4] [8.2, 7.4, 5.4]
forearmProf = LimbProfile [0, 0.3, 1] [5.6, 6.0, 3.7] [5.6, 5.7, 3.7]

organicLimb :: Pt -> Pt -> LimbProfile -> Double -> [ShapePrim]
organicLimb a@(ax, ay) b@(bx, by) (LimbProfile ts ls rs) k =
  let pts = [(ax + (bx - ax) * t, ay + (by - ay) * t) | t <- ts]
      ls' = map (* k) ls
      rs' = map (* k) rs
      rStart = case (ls', rs') of (l0 : _, r0 : _) -> max l0 r0; _ -> 6.0
      rEnd = min (last ls') (last rs')
   in [sPoly (ribbonPts pts ls' rs'), sCircle a rStart, sCircle b rEnd]

handShapes :: Pt -> Pt -> HandShape -> Double -> [ShapePrim]
handShapes elbow wrist shape k =
  let dir = ptUnit (ptSub wrist elbow)
      (_, ryNeg) = ptRot dir (-90)
      (_, ryPos) = ptRot dir 90
      upSide = if ryNeg <= ryPos then -1.0 else 1.0
      bend deg = ptRot dir (deg * upSide)
   in case shape of
        HandFinger ->
          let f = bend 12
              w2 = ptAdd wrist dir 2
              tip = ptAdd wrist f (13 * k)
           in [sCircle w2 (3.6 * k), sPoly (taperPts w2 tip (2.1 * k) (1.3 * k)), sCircle tip (1.3 * k)]
        HandPalm ->
          let f = bend 28
              n = ptRot f (90 * upSide)
              base = ptAdd wrist dir 1.5
              mid = ptAdd base f (6 * k)
              tip = ptAdd base f (11 * k)
              outline =
                [ ptAdd base n (3.4 * k),
                  ptAdd mid n (3.4 * k),
                  ptAdd tip n (2.3 * k),
                  ptAdd tip f (1.8 * k),
                  ptAdd tip n (-2.3 * k),
                  ptAdd mid n (-3.2 * k),
                  ptAdd base n (-3.2 * k)
                ]
              thumb = taperPts (ptAdd base f (2 * k)) (ptAdd (ptAdd base f (4 * k)) n (5 * k)) (1.8 * k) (1.3 * k)
           in [sPoly (closedCurvePts outline), sPoly thumb]
        HandFist ->
          let c = ptAdd wrist dir (3.6 * k)
              n = ptRot dir 90
              w = 4.8 * k
              h = 4.6 * k
              pts =
                [ ptAdd (ptAdd c dir (-h)) n (w * 0.8),
                  ptAdd (ptAdd c dir (h * 0.7)) n w,
                  ptAdd (ptAdd c dir h) n 0,
                  ptAdd (ptAdd c dir (h * 0.7)) n (-w),
                  ptAdd (ptAdd c dir (-h)) n (-w * 0.8)
                ]
           in [sPoly (closedCurvePts pts)]

footShapes :: Pt -> Pt -> Bool -> Double -> [ShapePrim]
footShapes knee ankle planted k =
  let (fx, fy) = if planted then (1.0, 0.0) else ptUnit (ptRot (ptUnit (ptSub ankle knee)) (-18))
      up@(ux, uy) = (fy, -fx)
      (gx, gy) = ptAdd ankle up (-ankleHeight)
      mkPt x h = (gx + fx * x * k + ux * h, gy + fy * x * k + uy * h)
      shoe =
        [ mkPt (-5) 0.6,
          mkPt (-5.6) 3.4,
          mkPt (-3.6) 7.0,
          mkPt 2.6 6.6,
          mkPt 8.0 3.6,
          mkPt 13.0 1.5,
          mkPt 13.8 0.4,
          mkPt 4.0 (-0.2)
        ]
   in [sCircle ankle (4.1 * k), sPoly (closedCurvePts shoe)]

headShape :: Pt -> Pt -> Double -> ShapePrim
headShape (cx, cy) (ux, uy) r =
  let (fx, fy) = (uy, -ux)
      rawPts =
        [ (0.08, 1.0),
          (-0.62, 0.84),
          (-0.98, 0.3),
          (-0.92, -0.32),
          (-0.52, -0.78),
          (0.12, -0.98),
          (0.58, -0.8),
          (0.84, -0.36),
          (0.9, 0.2),
          (0.66, 0.74)
        ]
      pts = [(cx + fx * x * r + ux * y * r, cy + fy * x * r + uy * y * r) | (x, y) <- rawPts]
   in sPoly (closedCurvePts pts)

rotatedPoly :: Pt -> Double -> [Pt] -> [Pt]
rotatedPoly (ox, oy) deg pts =
  let r = degToRad deg
      c = cos r
      s = sin r
   in [(ox + x * c - y * s, oy + x * s + y * c) | (x, y) <- pts]

swingWave :: Double -> Double -> Double
swingWave phase lag = sin (phase / 300.0 - lag) + sin (phase / 170.0 - lag * 1.6) * 0.4

buildActorParts :: SvgPose -> CombatStyle -> VisualProfile -> LookStyle -> Pt -> Double -> [ActorPart]
buildActorParts p style profile look (flowX, flowY) hairPhase =
  let maiden = profile == ProfileFemale && look == LookMaiden
      k = if maiden then 0.86 else 1.0
      b = spBones p
      headR = bHeadRadius b - (if maiden then 1.2 else 0.0)
      torsoAxis = ptUnit (ptSub (spNeck p) (spHip p))
      chest = ptAdd (spNeck p) torsoAxis (-10.0)
      waist = ptAdd (spHip p) torsoAxis 14.0
      bladeDir = dirVec (spBlade p)
      pommel = ptAdd (spHand p) bladeDir (-9.0)
      tasselVec = ptSub (spTassel p) pommel
      tasselEnd = ptAdd pommel (ptUnit tasselVec) (min (ptLen tasselVec) 20.0)
      headUp@(ux, uy) = ptUnit (ptSub (spHead p) (spNeck p))
      headBack@(bx, by) = (uy, -ux)
      headC@(hcx, hcy) = if maiden then ptAdd (spHead p) headUp (-1.2) else spHead p
      root@(rx, ry) = ptAdd (ptAdd (spHead p) headUp (headR * 0.5)) headBack (headR * 0.62)
      (handF, handB) = spHands p

      backLegShapes =
        organicLimb (spHip p) (spBackKnee p) thighProf k
          <> organicLimb (spBackKnee p) (spBackFoot p) shinProf k
          <> footShapes (spBackKnee p) (spBackFoot p) (spBackFootPlanted p) k
      backArmShapes =
        organicLimb (spShoulder p) (spBackElbow p) upperArmProf k
          <> organicLimb (spBackElbow p) (spBackHand p) forearmProf k
          <> handShapes (spBackElbow p) (spBackHand p) handB k

      chestR = if maiden then 11.4 else 13.5
      waistR = if maiden then 8.6 else 10.6
      pelvisR = if maiden then 11.0 else 11.5
      bodyShapes =
        [ sPoly (ribbonPts [chest, waist, spHip p] [chestR, waistR, pelvisR] [chestR, waistR, pelvisR]),
          sCircle chest chestR,
          sCircle (spHip p) pelvisR,
          sPoly (taperPts (spNeck p) headC (8.0 * k) (8.0 * k)),
          headShape headC headUp headR
        ]

      frontLegShapes =
        organicLimb (spHip p) (spKnee p) thighProf k
          <> organicLimb (spKnee p) (spFoot p) shinProf k
          <> footShapes (spKnee p) (spFoot p) (spFootPlanted p) k

      swordShapes =
        if style == StyleSword
          then
            let l = svgSwordLength
             in [ SPoly (taperPts pommel tasselEnd 1.6 1.2) Nothing 0.85,
                  sPoly (rotatedPoly (spHand p) (spBlade p) [(-9, -2), (5, -2), (5, 2), (-9, 2)]),
                  sPoly (rotatedPoly (spHand p) (spBlade p) [(4, -7), (7, -7), (7, 7), (4, 7)]),
                  SPoly (rotatedPoly (spHand p) (spBlade p) [(7, -2), (l - 8, -2), (l, 0), (l - 8, 2), (7, 2)]) (Just "#f2ead2") 1.0
                ]
          else []

      frontArmShapes =
        organicLimb (spShoulder p) (spElbow p) upperArmProf k
          <> organicLimb (spElbow p) (spHand p) forearmProf k
          <> swordShapes
          <> handShapes (spElbow p) (spHand p) (if style == StyleSword then HandFist else handF) k

      (mHairPart, extraBodyJoins)
        | profile /= ProfileFemale = (Nothing, [])
        | maiden =
            let sway1 = swingWave hairPhase 0.4 * 2.5
                sway2 = swingWave hairPhase 1.1 * 6.0
                onFace u bk = (hcx + ux * headR * u + bx * headR * bk, hcy + uy * headR * u + by * headR * bk)
                bun = onFace 0.5 0.98
                bunTop = onFace 0.82 0.72
                pinDir = ptUnit (ux * 0.3 + bx * 0.95, uy * 0.3 + by * 0.95)
                looseRoot@(lrx, lry) = onFace 0.05 0.86
                hPt bk down f sw = (lrx + bx * (bk + sw) + flowX * f, lry + by * (bk + sw) + down + flowY * f)
                hShapes =
                  [ sPoly (ribbonPts [hPt 8 8 0.2 0, hPt 14 18 0.9 sway1, hPt 19 28 1.5 (sway1 * 1.5)] [1.6, 1.2, 0.3] [1.6, 1.2, 0.3]),
                    sPoly (ribbonPts [ptAdd looseRoot headBack 2, hPt 10 14 0.3 (sway1 * 0.5), hPt 15 38 1.1 (sway1 * 1.2), hPt 13 55 1.8 (sway2 * 1.3)] [2.8, 2.8, 2.0, 0.3] [2.8, 2.8, 2.0, 0.3]),
                    sPoly (ribbonPts [hPt 1 4 0 0, hPt 3 26 0.5 (sway1 * 0.8), hPt 1 50 1.2 (sway2 * 0.9), hPt (-2) 68 1.7 (sway2 * 1.1)] [2.2, 2.0, 1.4, 0.3] [2.2, 2.0, 1.4, 0.3]),
                    sPoly (ribbonPts [looseRoot, hPt 6 10 0.2 0, hPt 9 32 0.8 sway1, hPt 5 61 1.5 sway2] [4.2, 4.6, 3.4, 0.4] [4.2, 4.6, 3.4, 0.4]),
                    sPoly (taperPts (ptAdd bun pinDir (-9)) (ptAdd bun pinDir 15) 1.5 0.6),
                    sCircle bun 6.8,
                    sCircle bunTop 4.6
                  ]
             in ( Just (ActorPart "hair" hShapes []),
                  [ JoinPatch looseRoot 10.0 (hShapes <> bodyShapes),
                    JoinPatch bun 8.0 (hShapes <> bodyShapes)
                  ]
                )
        | otherwise =
            let sway1 = swingWave hairPhase 0.4 * 2.5
                sway2 = swingWave hairPhase 1.1 * 6.0
                onHead u bk = (rx + ux * u + bx * bk, ry + uy * u + by * bk)
                hanging bk down f sw = (rx + bx * bk + flowX * f + sw, ry + by * bk + down + flowY * f)
                apex = onHead 4 9
                hShapes =
                  [ sPoly (ribbonPts [hanging 22 14 0.45 sway1, hanging 27 36 1.0 (sway1 * 1.2), hanging 26 54 1.7 (sway2 * 1.25)] [3.4, 2.6, 0.5] [3.4, 2.6, 0.5]),
                    sPoly (ribbonPts [onHead (-2) (-1), apex, hanging 21 8 0.3 (sway1 * 0.4), hanging 22 34 0.9 sway1, hanging 15 64 1.6 sway2] [3.6, 5.2, 6.4, 5.0, 0.6] [3.6, 5.2, 6.4, 5.0, 0.6]),
                    sCircle (onHead 1 1) 4.6
                  ]
             in ( Just (ActorPart "hair" hShapes []),
                  [JoinPatch root 8.0 (hShapes <> bodyShapes)]
                )

      baseBodyJoins =
        [ JoinPatch (spHip p) (10.5 * k + 10.0) (backLegShapes <> bodyShapes),
          JoinPatch (spShoulder p) (8.4 * k + 8.0) (backArmShapes <> bodyShapes)
        ]
      bodyPart = ActorPart "body" bodyShapes (baseBodyJoins <> extraBodyJoins)
      frontLegPart =
        ActorPart
          "front-leg"
          frontLegShapes
          [JoinPatch (spHip p) (10.5 * k + 10.0) (backLegShapes <> bodyShapes <> frontLegShapes)]
      frontArmPart =
        ActorPart
          "front-arm"
          frontArmShapes
          [JoinPatch (spShoulder p) (8.4 * k + 8.0) (backArmShapes <> bodyShapes <> frontArmShapes)]
   in maybe [] pure mHairPart
        <> [ActorPart "back-leg" backLegShapes [], ActorPart "back-arm" backArmShapes [], bodyPart, frontLegPart, frontArmPart]
