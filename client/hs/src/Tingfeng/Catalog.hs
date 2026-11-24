{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Tingfeng.Catalog
  ( PinPoint (..),
    pinPointText,
    TargetReaction (..),
    FrameHold (..),
    PoseKey (..),
    OffsetEase (..),
    OffsetKey (..),
    HitDef (..),
    ApproachDef (..),
    KeyPosesDef (..),
    Choreography (..),
    CameraStaging (..),
    TrailStaging (..),
    ReactionLook (..),
    StagingProfile (..),
    ActionDef (..),
    ActionCatalog (..),
    parseActionCatalog,
    stagingFor,
    battleActionFor,
    defaultActionIdForStyle,
    idleActionIdForStyle,
    reactionActionIdForStyle,
    isTravelMotion,
  )
where

import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Tingfeng.Json
import Tingfeng.Pose (CombatStyle (..), parseCombatStyle)
import Tingfeng.Protocol (CombatResult (..))

data PinPoint = PinHand | PinFoot | PinBlade
  deriving (Show, Eq)

pinPointText :: PinPoint -> Text
pinPointText PinHand = "hand"
pinPointText PinFoot = "foot"
pinPointText PinBlade = "blade"

parsePin :: Text -> Maybe PinPoint
parsePin "hand" = Just PinHand
parsePin "foot" = Just PinFoot
parsePin "blade" = Just PinBlade
parsePin _ = Nothing

data TargetReaction = ReactHit | ReactDodge | ReactParry | ReactEffect | ReactNone
  deriving (Show, Eq, Ord)

parseReaction :: Text -> TargetReaction
parseReaction "hit" = ReactHit
parseReaction "dodge" = ReactDodge
parseReaction "parry" = ReactParry
parseReaction "effect" = ReactEffect
parseReaction _ = ReactNone

data FrameHold = FrameHold
  { fhFrameId :: !Text,
    fhHoldMs :: !Double
  }
  deriving (Show, Eq)

data PoseKey = PoseKey
  { pkAtMs :: !Double,
    pkPose :: !Text,
    pkPin :: !(Maybe PinPoint),
    pkReach :: !(Maybe Double),
    pkContactY :: !(Maybe Double)
  }
  deriving (Show, Eq)

data OffsetEase = EaseCut | EaseLinear | EaseOut
  deriving (Show, Eq)

data OffsetKey = OffsetKey
  { okAtMs :: !Double,
    okX :: !Double,
    okY :: !Double,
    okAngle :: !Double,
    okEase :: !OffsetEase
  }
  deriving (Show, Eq)

data HitDef = HitDef
  { hdAtMs :: !Double,
    hdHitStopMs :: !Double,
    hdShare :: !Double,
    hdStaging :: !(Maybe JVal)
  }
  deriving (Show, Eq)

data ApproachDef = ApproachDef
  { apPose :: !Text,
    apDurationMs :: !Double,
    apLift :: !Double
  }
  deriving (Show, Eq)

data KeyPosesDef = KeyPosesDef
  { kpPrepare :: !(Maybe Text),
    kpContact :: !(Maybe Text),
    kpFinish :: !(Maybe Text),
    kpRetreat :: !(Maybe Text),
    kpReachWith :: !(Maybe PinPoint)
  }
  deriving (Show, Eq)

data Choreography = Choreography
  { chLaunchAtMs :: !Double,
    chHitStopMs :: !Double,
    chRecoverAtMs :: !Double,
    chRestAtMs :: !Double,
    chReach :: !Double,
    chContactY :: !Double,
    chWeight :: !Text
  }
  deriving (Show, Eq)

data CameraStaging = CameraStaging
  { csKick :: !Double,
    csRebound :: !Double,
    csLift :: !Double,
    csZoom :: !Double
  }
  deriving (Show, Eq)

data TrailStaging = TrailStaging
  { tsLeadMs :: !Double,
    tsFadeMs :: !Double
  }
  deriving (Show, Eq)

data ReactionLook = ReactionLook
  { rlPush :: !Double,
    rlTilt :: !Double,
    rlLift :: !Double,
    rlSnap :: !Double,
    rlLeadMs :: !Double,
    rlOnsetMs :: !Double,
    rlGhost :: !Double,
    rlHop :: !Double,
    rlStandoff :: !Double,
    rlPose :: !(Maybe Text)
  }
  deriving (Show, Eq)

data StagingProfile = StagingProfile
  { spForce :: !Double,
    spCamera :: !CameraStaging,
    spShade :: !Double,
    spTilt :: !Double,
    spFlash :: !Double,
    spFallMs :: !Double,
    spTrail :: !TrailStaging,
    spReactHit :: !ReactionLook,
    spReactDodge :: !ReactionLook,
    spReactParry :: !ReactionLook
  }
  deriving (Show, Eq)

data ActionDef = ActionDef
  { adId :: !Text,
    adLabel :: !Text,
    adStyle :: !CombatStyle,
    adFrames :: ![FrameHold],
    adImpactFrame :: !Int,
    adDurationMs :: !Double,
    adTags :: ![Text],
    adActorMotion :: !Text,
    adKeyPoses :: !(Maybe KeyPosesDef),
    adApproach :: !(Maybe ApproachDef),
    adHits :: ![HitDef],
    adPoseTrack :: ![PoseKey],
    adOffsetTrack :: ![OffsetKey],
    adTargetReaction :: !(M.Map CombatResult TargetReaction),
    adChoreography :: !Choreography,
    adStaging :: !(Maybe JVal)
  }
  deriving (Show, Eq)

data ActionCatalog = ActionCatalog
  { acActions :: !(M.Map Text ActionDef),
    acOrder :: ![Text],
    acPresets :: !(M.Map Text StagingProfile)
  }
  deriving (Show, Eq)

isTravelMotion :: Text -> Bool
isTravelMotion m = m == "approach" || m == "lunge" || m == "drive"

defaultLightStaging :: StagingProfile
defaultLightStaging =
  StagingProfile
    { spForce = 0.6,
      spCamera = CameraStaging 3.5 0.35 0.35 0.02,
      spShade = 0.09,
      spTilt = 0.0,
      spFlash = 0.75,
      spFallMs = 180.0,
      spTrail = TrailStaging 85.0 170.0,
      spReactHit = ReactionLook 34.0 0.0 4.0 0.65 0.0 0.0 0.0 0.0 0.0 Nothing,
      spReactDodge = ReactionLook 80.0 0.0 0.0 1.0 110.0 120.0 0.32 0.0 0.0 Nothing,
      spReactParry = ReactionLook 4.0 0.0 0.0 1.0 50.0 65.0 0.0 0.0 26.0 Nothing
    }

applyStagingOverride :: JVal -> StagingProfile -> StagingProfile
applyStagingOverride (JObj m) base =
  let cam = case M.lookup "camera" m of
        Just (JObj cm) ->
          CameraStaging
            (jFieldDef (csKick (spCamera base)) jDouble "kick" cm)
            (jFieldDef (csRebound (spCamera base)) jDouble "rebound" cm)
            (jFieldDef (csLift (spCamera base)) jDouble "lift" cm)
            (jFieldDef (csZoom (spCamera base)) jDouble "zoom" cm)
        _ -> spCamera base
      trl = case M.lookup "trail" m of
        Just (JObj tm) ->
          TrailStaging
            (jFieldDef (tsLeadMs (spTrail base)) jDouble "leadMs" tm)
            (jFieldDef (tsFadeMs (spTrail base)) jDouble "fadeMs" tm)
        _ -> spTrail base
      mergeLook rk rBase = case M.lookup "reactions" m >>= jMap >>= M.lookup rk >>= jMap of
        Nothing -> rBase
        Just rm ->
          ReactionLook
            { rlPush = jFieldDef (rlPush rBase) jDouble "push" rm,
              rlTilt = jFieldDef (rlTilt rBase) jDouble "tilt" rm,
              rlLift = jFieldDef (rlLift rBase) jDouble "lift" rm,
              rlSnap = jFieldDef (rlSnap rBase) jDouble "snap" rm,
              rlLeadMs = jFieldDef (rlLeadMs rBase) jDouble "leadMs" rm,
              rlOnsetMs = jFieldDef (rlOnsetMs rBase) jDouble "onsetMs" rm,
              rlGhost = jFieldDef (rlGhost rBase) jDouble "ghost" rm,
              rlHop = jFieldDef (rlHop rBase) jDouble "hop" rm,
              rlStandoff = jFieldDef (rlStandoff rBase) jDouble "standoff" rm,
              rlPose = maybe (rlPose rBase) Just (jFieldMaybe jText "pose" rm)
            }
   in StagingProfile
        { spForce = jFieldDef (spForce base) jDouble "force" m,
          spCamera = cam,
          spShade = jFieldDef (spShade base) jDouble "shade" m,
          spTilt = jFieldDef (spTilt base) jDouble "tilt" m,
          spFlash = jFieldDef (spFlash base) jDouble "flash" m,
          spFallMs = jFieldDef (spFallMs base) jDouble "fallMs" m,
          spTrail = trl,
          spReactHit = mergeLook "hit" (spReactHit base),
          spReactDodge = mergeLook "dodge" (spReactDodge base),
          spReactParry = mergeLook "parry" (spReactParry base)
        }
applyStagingOverride _ base = base

stagingFor :: ActionCatalog -> Text -> [Maybe JVal] -> StagingProfile
stagingFor cat weight overrides =
  let base = M.findWithDefault defaultLightStaging weight (acPresets cat)
   in foldl' (\acc mOv -> maybe acc (`applyStagingOverride` acc) mOv) base overrides

parseActionCatalog :: Text -> [Text] -> Either String ActionCatalog
parseActionCatalog stagingRaw manifestRaws = do
  stgVal <- parseJson stagingRaw
  presets <- case stgVal of
    JObj sm -> case M.lookup "presets" sm of
      Just (JObj pm) -> do
        let light = maybe defaultLightStaging (`applyStagingOverride` defaultLightStaging) (M.lookup "light" pm)
            resolvePreset k = case M.lookup k pm of
              Just v@(JObj vm) ->
                let parent = case jField jText "extends" vm of
                      Just "light" -> light
                      _ -> defaultLightStaging
                 in applyStagingOverride v parent
              _ -> light
        Right (M.fromList [(k, resolvePreset k) | k <- M.keys pm])
      _ -> Right (M.singleton "light" defaultLightStaging)
    _ -> Right (M.singleton "light" defaultLightStaging)

  manifests <- traverse parseJson manifestRaws
  let actions = concatMap extractActions manifests
      order = map adId actions
      mp = M.fromList [(adId a, a) | a <- actions]
  Right (ActionCatalog mp order presets)
  where
    extractActions (JObj m) =
      maybe [] (mapMaybe decAction) (jField (jList Just) "actions" m)
    extractActions _ = []

    decFrame (JObj m) =
      Just $
        FrameHold
          (jFieldDef "idle" jText "frameId" m)
          (jFieldDef 200 jDouble "holdMs" m)
    decFrame _ = Nothing

    decPoseKey (JObj m) =
      Just $
        PoseKey
          { pkAtMs = jFieldDef 0 jDouble "atMs" m,
            pkPose = jFieldDef "idle" jText "pose" m,
            pkPin = jField jText "pin" m >>= parsePin,
            pkReach = jFieldMaybe jDouble "reach" m,
            pkContactY = jFieldMaybe jDouble "contactY" m
          }
    decPoseKey _ = Nothing

    decEase (Just "linear") = EaseLinear
    decEase (Just "out") = EaseOut
    decEase _ = EaseCut

    decOffsetKey (JObj m) =
      Just $
        OffsetKey
          { okAtMs = jFieldDef 0 jDouble "atMs" m,
            okX = jFieldDef 0 jDouble "x" m,
            okY = jFieldDef 0 jDouble "y" m,
            okAngle = jFieldDef 0 jDouble "angle" m,
            okEase = decEase (jField jText "ease" m)
          }
    decOffsetKey _ = Nothing

    decHitDef (JObj m) =
      Just $
        HitDef
          { hdAtMs = jFieldDef 0 jDouble "atMs" m,
            hdHitStopMs = jFieldDef 0 jDouble "hitStopMs" m,
            hdShare = jFieldDef 1.0 jDouble "share" m,
            hdStaging = M.lookup "staging" m
          }
    decHitDef _ = Nothing

    decApproach (JObj m) =
      Just $
        ApproachDef
          (jFieldDef "approach" jText "pose" m)
          (jFieldDef 260 jDouble "durationMs" m)
          (jFieldDef 10 jDouble "lift" m)
    decApproach _ = Nothing

    decKeyPoses (JObj m) =
      Just $
        KeyPosesDef
          { kpPrepare = jFieldMaybe jText "prepare" m,
            kpContact = jFieldMaybe jText "contact" m,
            kpFinish = jFieldMaybe jText "finish" m,
            kpRetreat = jFieldMaybe jText "retreat" m,
            kpReachWith = jField jText "reachWith" m >>= parsePin
          }
    decKeyPoses _ = Nothing

    decChoreo (JObj m) =
      Choreography
        { chLaunchAtMs = jFieldDef 0 jDouble "launchAtMs" m,
          chHitStopMs = jFieldDef 0 jDouble "hitStopMs" m,
          chRecoverAtMs = jFieldDef 360 jDouble "recoverAtMs" m,
          chRestAtMs = jFieldDef 640 jDouble "restAtMs" m,
          chReach = jFieldDef 0 jDouble "reach" m,
          chContactY = jFieldDef 110 jDouble "contactY" m,
          chWeight = jFieldDef "light" jText "weight" m
        }
    decChoreo _ = Choreography 0 0 360 640 0 110 "light"

    decReactions (JObj m) =
      M.fromList
        [ (ResHit, maybe ReactHit parseReaction (jField jText "hit" m)),
          (ResDodge, maybe ReactDodge parseReaction (jField jText "dodge" m)),
          (ResParry, maybe ReactParry parseReaction (jField jText "parry" m)),
          (ResEffect, maybe ReactEffect parseReaction (jField jText "effect" m))
        ]
    decReactions _ = M.empty

    decAction (JObj m) = do
      aid <- jField jText "id" m
      let frames = maybe [FrameHold "idle" 640] (mapMaybe decFrame) (jField (jList Just) "frames" m)
          choreo = maybe (Choreography 0 0 360 640 0 110 "light") decChoreo (M.lookup "choreography" m)
      Just $
        ActionDef
          { adId = aid,
            adLabel = jFieldDef aid jText "label" m,
            adStyle = parseCombatStyle (jFieldDef "fist" jText "style" m),
            adFrames = if null frames then [FrameHold "idle" 640] else frames,
            adImpactFrame = jFieldDef 0 jInt "impactFrame" m,
            adDurationMs = jFieldDef 640 jDouble "durationMs" m,
            adTags = fromMaybe [] (jField (jList jText) "tags" m),
            adActorMotion = jFieldDef "none" jText "actorMotion" m,
            adKeyPoses = M.lookup "keyPoses" m >>= decKeyPoses,
            adApproach = M.lookup "approach" m >>= decApproach,
            adHits = maybe [] (mapMaybe decHitDef) (jField (jList Just) "hits" m),
            adPoseTrack = maybe [] (mapMaybe decPoseKey) (jField (jList Just) "poseTrack" m),
            adOffsetTrack = maybe [] (mapMaybe decOffsetKey) (jField (jList Just) "offsetTrack" m),
            adTargetReaction = maybe M.empty decReactions (M.lookup "targetReaction" m),
            adChoreography = choreo,
            adStaging = M.lookup "staging" m
          }
    decAction _ = Nothing

defaultActionIdForStyle :: CombatStyle -> Text
defaultActionIdForStyle StyleSword = "rig.sword.chop_a"
defaultActionIdForStyle StyleFist = "rig.fist.punch_a"

idleActionIdForStyle :: CombatStyle -> Text
idleActionIdForStyle StyleSword = "rig.sword.idle"
idleActionIdForStyle StyleFist = "rig.fist.idle"

reactionActionIdForStyle :: TargetReaction -> CombatStyle -> Text
reactionActionIdForStyle ReactHit StyleSword = "rig.sword.hurt"
reactionActionIdForStyle ReactHit StyleFist = "rig.fist.hurt"
reactionActionIdForStyle ReactDodge StyleSword = "rig.sword.dodge"
reactionActionIdForStyle ReactDodge StyleFist = "rig.fist.dodge"
reactionActionIdForStyle ReactParry StyleSword = "rig.sword.parry"
reactionActionIdForStyle ReactParry StyleFist = "rig.fist.parry"
reactionActionIdForStyle _ style = idleActionIdForStyle style

fallbackAction :: CombatStyle -> ActionDef
fallbackAction style =
  ActionDef
    { adId = idleActionIdForStyle style,
      adLabel = "待机",
      adStyle = style,
      adFrames = [FrameHold "idle" 640],
      adImpactFrame = 0,
      adDurationMs = 640,
      adTags = [],
      adActorMotion = "none",
      adKeyPoses = Nothing,
      adApproach = Nothing,
      adHits = [],
      adPoseTrack = [],
      adOffsetTrack = [],
      adTargetReaction = M.empty,
      adChoreography = Choreography 0 0 360 640 0 110 "quiet",
      adStaging = Nothing
    }

battleActionFor :: ActionCatalog -> Text -> CombatStyle -> ActionDef
battleActionFor cat aid fallbackStyle =
  case M.lookup aid (acActions cat) of
    Just a -> a
    Nothing ->
      fromMaybe
        (fallbackAction fallbackStyle)
        (M.lookup (defaultActionIdForStyle fallbackStyle) (acActions cat))
