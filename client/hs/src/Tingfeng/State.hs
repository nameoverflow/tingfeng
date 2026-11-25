{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Tingfeng.State
  ( AppPage (..),
    LogLine (..),
    HitTarget (..),
    CanvasHitbox (..),
    ScrollTarget (..),
    ScrollZone (..),
    ClientCmd (..),
    PresentationState (..),
    QueuedBattle (..),
    ClientModel (..),
    worldPosFromGrid,
    isCameraPanned,
    initClientModel,
    stepClientFrame,
    applyServerMessage,
    setDocumentHidden,
    handlePointerMove,
    handlePointerClick,
    handleDragAt,
    handleScrollAt,
    handleTextInput,
    handleTextSubmit,
    handleFocusInputId,
    handleBlurInput,
    handleKeyDown,
    panCameraBy,
    zoomCameraBy,
    resetCameraPan,
    handleUiAction,
    handleLabCommand,
    buildLabStateJson,
    portraitScoreFile,
    liveEffectsOf,
    evalSkillState,
    SkillEval (..),
    labActionOrder,
  )
where

import Data.List (find)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Tingfeng.Battle
import Tingfeng.Catalog
import Tingfeng.I18n
import Tingfeng.Json
import Tingfeng.Pose
import Tingfeng.Protocol

data AppPage = PageGame | PageBattleLab | PagePoseSheet
  deriving (Show, Eq)

data LogLine = LogLine
  { llId :: !Int,
    llKind :: !Text,
    llText :: !Text
  }
  deriving (Show, Eq)

data HitTarget
  = HitExit !Direction
  | HitNpc !Text
  | HitResetCam
  | HitUi !Text !Text !Text
  | HitFocusInput !Text
  | HitLab !Text !Text !Text !Text !Double
  | HitLabScrub !Double !Double
  | HitSwallow
  deriving (Show, Eq)

data CanvasHitbox = CanvasHitbox
  { chX :: !Double,
    chY :: !Double,
    chW :: !Double,
    chH :: !Double,
    chTarget :: !HitTarget,
    chCursor :: !Text
  }
  deriving (Show, Eq)

data ScrollTarget = ScrollLog | ScrollDrawer | ScrollOnboard | ScrollNpc
  deriving (Show, Eq)

data ScrollZone = ScrollZone
  { szX :: !Double,
    szY :: !Double,
    szW :: !Double,
    szH :: !Double,
    szTarget :: !ScrollTarget
  }
  deriving (Show, Eq)

data ClientCmd
  = CmdSendWs !Text
  | CmdConnectWs !Text !Text !(Maybe CreationChoice)
  | CmdOpenConfigWs
  | CmdSetCursor !Text
  | CmdPlaySfx !Text
  | CmdSaveLocal !Text !Text
  | CmdFocusInput !Text !Text !Double !Double !Double !Double
  | CmdBlurInput
  deriving (Show, Eq)

data PresentationState = PresentationState
  { prPlayerHp :: !Int,
    prEnemyHp :: !Int,
    prPlayerQi :: !Int,
    prEnemyQi :: !Int,
    prPlayerEffects :: ![EffectInfo],
    prEnemyEffects :: ![EffectInfo]
  }
  deriving (Show, Eq)

data QueuedBattle
  = QCombat !CombatEvt !(Maybe PresentationState)
  | QSettlement !Text !Text !Bool
  deriving (Show, Eq)

data ClientModel = ClientModel
  { cmPage :: !AppPage,
    cmLocale :: !Locale,
    cmPoseLib :: !PoseLibrary,
    cmCatalog :: !ActionCatalog,
    cmReducedMotion :: !Bool,
    cmDocHidden :: !Bool,
    cmSoundOn :: !Bool,
    cmLookStyle :: !LookStyle,
    cmWidth :: !Double,
    cmHeight :: !Double,
    cmClockMs :: !Double,
    cmLastSyncTickMs :: !Double,
    cmWasmStepMs :: !Double,
    cmDrawCmdCount :: !Int,
    -- Connection & Onboarding
    cmConnected :: !Bool,
    cmConnecting :: !Bool,
    cmUsername :: !Text,
    cmLastError :: !(Maybe Text),
    cmLoginMode :: !Text, -- "login" | "create"
    cmCreateStep :: !Int,
    cmCreationCfg :: !(Maybe CreationConfig),
    cmCreateChoice :: !CreationChoice,
    -- World & Stats
    cmStats :: !PlayerStatsInfo,
    cmStatsSyncedAtMs :: !Double,
    cmMoney :: !Int,
    cmRoomName :: !Text,
    cmRoomDesc :: !Text,
    cmRoomChars :: ![RoomChar],
    cmRoomExits :: ![RoomExit],
    cmMapOverview :: !(Maybe MapOverview),
    cmMapCache :: !(M.Map Text MapOverview),
    cmRequestedInit :: !Bool,
    -- Camera & Map Pan/Zoom
    cmCamX :: !Double,
    cmCamY :: !Double,
    cmCamVx :: !Double,
    cmCamVy :: !Double,
    cmTargetCamX :: !Double,
    cmTargetCamY :: !Double,
    cmPanX :: !Double,
    cmPanY :: !Double,
    cmMapZoom :: !Double,
    -- Battle & Deterministic Timeline Queue
    cmInBattle :: !Bool,
    cmStoryActive :: !Bool,
    cmStoryQueue :: ![ServerMsg],
    cmStoryDelayRemMs :: !Double,
    cmTransitionBanner :: !(Maybe (Text, Double)),
    cmBattleSnap :: !(Maybe BattleSnap),
    cmCooldownSyncedMs :: !Double,
    cmActionLockUntilMs :: !Double,
    cmPresentation :: !(Maybe PresentationState),
    cmPreEventSnap :: !(Maybe PresentationState),
    cmActiveTimeline :: !(Maybe ResolvedTimeline),
    cmTimelineElapsedMs :: !Double,
    cmAppliedHits :: !Int,
    cmNextTimelineId :: !Int,
    cmBattleQueue :: ![QueuedBattle],
    cmLabPaused :: !Bool,
    cmLabSpeed :: !Double,
    cmPlayerHpTrail :: !Double,
    cmEnemyHpTrail :: !Double,
    cmPlayerApAnim :: !Double,
    cmEnemyApAnim :: !Double,
    cmPlayerHitFlashMs :: !Double,
    cmEnemyHitFlashMs :: !Double,
    cmParticles :: ![InkParticle],
    cmShockPos :: !Pt,
    cmShockAge :: !Double,
    cmShockPower :: !Double,
    -- Panels, Drawers, Scrolling, IME & Logs
    cmLogs :: ![LogLine],
    cmNextLogId :: !Int,
    cmUnreadLogs :: !Int,
    cmInventory :: ![InvItem],
    cmArts :: ![ArtInfo],
    cmQuests :: ![QuestItem],
    cmDesktopDrawer :: !Text, -- "" | "character" | "arts" | "quests"
    cmCharSubTab :: !Text, -- "status" | "inventory"
    cmMobileTab :: !Text, -- "world" | "log" | "arts" | "character" | "quests"
    cmSelectedNpc :: !(Maybe Text),
    cmFocusedInput :: !(Maybe Text), -- Nothing | Just "login" | Just "say"
    cmSayDraft :: !Text,
    cmDevReset :: !Bool,
    cmLogScroll :: !Double,
    cmLogMaxScroll :: !Double,
    cmLogStickBottom :: !Bool,
    cmDrawerScroll :: !Double,
    cmDrawerMaxScroll :: !Double,
    cmOnboardScroll :: !Double,
    cmOnboardMaxScroll :: !Double,
    cmNpcScroll :: !Double,
    cmNpcMaxScroll :: !Double,
    cmLabActionIdx :: !Int,
    cmLabOutcomeIdx :: !Int,
    cmLabSideIdx :: !Int,
    cmHovered :: !(Maybe HitTarget),
    cmHitboxes :: ![CanvasHitbox],
    cmScrollZones :: ![ScrollZone],
    cmUiDirty :: !Bool
  }
  deriving (Show)

apBaselineAgility :: Double
apBaselineAgility = 19.0

apGainPerAgilitySecond :: Double
apGainPerAgilitySecond = 100.0 / (2.0 * apBaselineAgility)

gridScaleX, gridScaleY :: Double
gridScaleX = 164.0
gridScaleY = 118.0

worldPosFromGrid :: (Int, Int) -> Pt
worldPosFromGrid (gx, gy) = (fromIntegral gx * gridScaleX, fromIntegral (-gy) * gridScaleY)

defaultStats :: PlayerStatsInfo
defaultStats =
  PlayerStatsInfo
    { psHp = 100,
      psMaxHp = 100,
      psQi = 100,
      psMaxQi = 100,
      psJing = 120,
      psMaxJing = 120,
      psAp = 0,
      psStatus = "normal",
      psGender = "female",
      psAppearance = 6,
      psAppearanceText = "",
      psPortraitKey = "beauty-score-06",
      psStrength = 18,
      psAgility = 18,
      psVitality = 18,
      psPotential = 0,
      psCombatExp = 0,
      psInjuredSeconds = 0,
      psCombatInsight = 0,
      psBusy = Nothing
    }

initClientModel :: AppPage -> PoseLibrary -> ActionCatalog -> Double -> Double -> Bool -> ClientModel
initClientModel page lib cat w h reduced =
  ClientModel
    { cmPage = page,
      cmLocale = Zh,
      cmPoseLib = lib,
      cmCatalog = cat,
      cmReducedMotion = reduced,
      cmDocHidden = False,
      cmSoundOn = False,
      cmLookStyle = LookMaiden,
      cmWidth = max 320 w,
      cmHeight = max 220 h,
      cmClockMs = 0,
      cmLastSyncTickMs = 0,
      cmWasmStepMs = 0.06,
      cmDrawCmdCount = 0,
      cmConnected = page /= PageGame,
      cmConnecting = False,
      cmUsername = "",
      cmLastError = Nothing,
      cmLoginMode = "login",
      cmCreateStep = 0,
      cmCreationCfg = Nothing,
      cmCreateChoice = CreationChoice "female" "" "" "",
      cmStats = defaultStats,
      cmStatsSyncedAtMs = 0,
      cmMoney = 0,
      cmRoomName = "",
      cmRoomDesc = "",
      cmRoomChars = [],
      cmRoomExits = [],
      cmMapOverview = Nothing,
      cmMapCache = M.empty,
      cmRequestedInit = False,
      cmCamX = 0,
      cmCamY = 0,
      cmCamVx = 0,
      cmCamVy = 0,
      cmTargetCamX = 0,
      cmTargetCamY = 0,
      cmPanX = 0,
      cmPanY = 0,
      cmMapZoom = 1.0,
      cmInBattle = False,
      cmStoryActive = False,
      cmStoryQueue = [],
      cmStoryDelayRemMs = 0,
      cmTransitionBanner = Nothing,
      cmBattleSnap = Nothing,
      cmCooldownSyncedMs = 0,
      cmActionLockUntilMs = 0,
      cmPresentation = Nothing,
      cmPreEventSnap = Nothing,
      cmActiveTimeline = Nothing,
      cmTimelineElapsedMs = 0,
      cmAppliedHits = 0,
      cmNextTimelineId = 1,
      cmBattleQueue = [],
      cmLabPaused = False,
      cmLabSpeed = 1.0,
      cmPlayerHpTrail = 1.0,
      cmEnemyHpTrail = 1.0,
      cmPlayerApAnim = 0.0,
      cmEnemyApAnim = 0.0,
      cmPlayerHitFlashMs = 0.0,
      cmEnemyHitFlashMs = 0.0,
      cmParticles = [],
      cmShockPos = (0.5, 0.5),
      cmShockAge = 99.0,
      cmShockPower = 0.0,
      cmLogs = [],
      cmNextLogId = 1,
      cmUnreadLogs = 0,
      cmInventory = [],
      cmArts = [],
      cmQuests = [],
      cmDesktopDrawer = "",
      cmCharSubTab = "status",
      cmMobileTab = "world",
      cmSelectedNpc = Nothing,
      cmFocusedInput = Nothing,
      cmSayDraft = "",
      cmDevReset = False,
      cmLogScroll = 0,
      cmLogMaxScroll = 0,
      cmLogStickBottom = True,
      cmDrawerScroll = 0,
      cmDrawerMaxScroll = 0,
      cmOnboardScroll = 0,
      cmOnboardMaxScroll = 0,
      cmNpcScroll = 0,
      cmNpcMaxScroll = 0,
      cmLabActionIdx = 0,
      cmLabOutcomeIdx = 0,
      cmLabSideIdx = 0,
      cmHovered = Nothing,
      cmHitboxes = [],
      cmScrollZones = [],
      cmUiDirty = True
    }

pushLog :: Text -> Text -> ClientModel -> ClientModel
pushLog kind txt m
  | T.null (T.strip txt) = m
  | otherwise =
      let lid = cmNextLogId m
          entry = LogLine lid kind txt
          prev = cmLogs m
          nextLogs = if length prev >= 80 then drop (length prev - 79) prev <> [entry] else prev <> [entry]
          unread =
            if cmMobileTab m == "world" || cmMobileTab m == "log" || not (cmConnected m)
              then 0
              else min 99 (cmUnreadLogs m + 1)
       in m {cmLogs = nextLogs, cmNextLogId = lid + 1, cmUnreadLogs = unread, cmUiDirty = True}

inferCurrentGrid :: [RoomExit] -> Maybe (Int, Int)
inferCurrentGrid exits =
  listToMaybe
    [ (px - dx, py - dy)
      | ex <- exits,
        Just (px, py) <- [rePos ex],
        let (dx, dy) = directionGridDelta (reDirection ex)
    ]

updateCameraTarget :: ClientModel -> ClientModel
updateCameraTarget m =
  let mGrid = case cmMapOverview m of
        Just mo -> Just (moCurrentPos mo)
        Nothing -> inferCurrentGrid (cmRoomExits m)
      (tx, ty) = maybe (0.0, 0.0) worldPosFromGrid mGrid
   in m {cmTargetCamX = tx, cmTargetCamY = ty}

currentStylesAndProfiles :: ClientModel -> (CombatStyle, CombatStyle, VisualProfile, VisualProfile, Text, Text)
currentStylesAndProfiles m =
  case cmBattleSnap m of
    Just bs ->
      let p = bsPlayer bs
          e = bsEnemy bs
       in ( parseCombatStyle (cbStyle p),
            parseCombatStyle (cbStyle e),
            parseVisualProfile (cbGender p),
            parseVisualProfile (cbGender e),
            cbName p,
            cbName e
          )
    Nothing ->
      ( StyleFist,
        StyleSword,
        parseVisualProfile (psGender (cmStats m)),
        ProfileMale,
        if T.null (cmUsername m) then "行者" else cmUsername m,
        "对手"
      )

formatCombatLogText :: Locale -> CombatEvt -> Text
formatCombatLogText loc ev
  | ceMsgKind ev == "effect_tick" =
      let amt = T.pack (show (ceEffectAmount ev))
       in if ceEffectKind ev == "hot"
            then ceText ev <> (if loc == Zh then "回复 " <> amt <> " 点气血" else " +" <> amt <> " HP")
            else ceText ev <> (if loc == Zh then "造成 " <> amt <> " 点伤害" else " -" <> amt <> " HP")
  | not (T.null (T.strip (ceText ev))) =
      let base = T.strip (ceText ev)
          suffix = case (ceResult ev, ceDamage ev, ceHeal ev) of
            (ResHit, Just d, _) | d > 0 -> "（-" <> T.pack (show d) <> " " <> tr loc "resource.hp" <> "）"
            (_, _, Just h) | h > 0 -> "（+" <> T.pack (show h) <> " " <> tr loc "resource.hp" <> "）"
            (ResDodge, _, _) -> if "闪" `T.isInfixOf` base then "" else "（闪避）"
            (ResParry, _, _) -> if "架" `T.isInfixOf` base then "" else "（招架）"
            _ -> ""
       in base <> suffix
  | otherwise = ceActorName ev <> " → " <> ceTargetName ev

snapToPresentation :: BattleSnap -> PresentationState
snapToPresentation bs =
  PresentationState
    (cbHp (bsPlayer bs))
    (cbHp (bsEnemy bs))
    (cbQi (bsPlayer bs))
    (cbQi (bsEnemy bs))
    (cbEffects (bsPlayer bs))
    (cbEffects (bsEnemy bs))

startNextBattleItem :: ClientModel -> (ClientModel, [ClientCmd])
startNextBattleItem m0 =
  case cmBattleQueue m0 of
    [] ->
      let alignedPres = case cmBattleSnap m0 of
            Just bs -> Just (snapToPresentation bs)
            Nothing -> cmPresentation m0
       in ( m0
              { cmActiveTimeline = Nothing,
                cmTimelineElapsedMs = 0,
                cmAppliedHits = 0,
                cmPresentation = alignedPres,
                cmUiDirty = True
              },
            []
          )
    (item : rest) ->
      let (pStyle, eStyle, pProf, eProf, pName, eName) = currentStylesAndProfiles m0
          tid = cmNextTimelineId m0
       in case item of
            QCombat ev mPreSnap ->
              let actorSide = if ceActorName ev == eName && ceActorName ev /= pName then SideEnemy else SidePlayer
                  targetSide
                    | ceTargetName ev == pName = SidePlayer
                    | ceTargetName ev == eName = SideEnemy
                    | actorSide == SidePlayer = SideEnemy
                    | otherwise = SidePlayer
                  logTxt = formatCombatLogText (cmLocale m0) ev
                  tl = resolveCombatTimeline (cmCatalog m0) ev tid actorSide targetSide logTxt
                         (if actorSide == SidePlayer then pProf else eProf)
                         (if targetSide == SidePlayer then pProf else eProf)
                         (if actorSide == SidePlayer then pStyle else eStyle)
                         (if targetSide == SidePlayer then pStyle else eStyle)
                  pres0 = case (cmPresentation m0, mPreSnap) of
                    (Just pr, _) -> pr
                    (Nothing, Just pr) -> pr
                    (Nothing, Nothing) ->
                      case cmBattleSnap m0 of
                        Just bs -> snapToPresentation bs
                        Nothing -> PresentationState (psHp (cmStats m0)) 100 (psQi (cmStats m0)) 100 [] []
                  sfxCmds = if cmSoundOn m0 && tlKind tl /= "effect_tick" then [CmdPlaySfx "whoosh"] else []
                  -- Snap acting combatant's AP when their action begins
                  (pApNext, eApNext) = case cmBattleSnap m0 of
                    Just bs ->
                      ( if actorSide == SidePlayer then cbApProgress (bsPlayer bs) else cmPlayerApAnim m0,
                        if actorSide == SideEnemy then cbApProgress (bsEnemy bs) else cmEnemyApAnim m0
                      )
                    Nothing -> (cmPlayerApAnim m0, cmEnemyApAnim m0)
                  m1 =
                    pushLog "combat" logTxt $
                      m0
                        { cmInBattle = True,
                          cmActiveTimeline = Just tl,
                          cmTimelineElapsedMs = 0.0,
                          cmAppliedHits = 0,
                          cmNextTimelineId = tid + 1,
                          cmBattleQueue = rest,
                          cmPresentation = Just pres0,
                          cmPlayerApAnim = pApNext,
                          cmEnemyApAnim = eApNext,
                          cmUiDirty = True
                        }
                  -- If impactAtMs == 0 (e.g. effect_tick), commit immediately!
                  (m2, hitCmds) = commitHitsUpTo 0.0 m1
               in if cmDocHidden m2
                    then drainImmediately m2
                    else (m2, sfxCmds <> hitCmds)
            QSettlement atk def win ->
              let actorSide = if win then SidePlayer else SideEnemy
                  targetSide = if win then SideEnemy else SidePlayer
                  enemyName = if atk == cmUsername m0 then def else atk
                  txt =
                    if cmLocale m0 == Zh
                      then (if win then "胜。与" else "败。与") <> enemyName <> "的交锋已分胜负。"
                      else (if win then "Victory against " else "Defeat against ") <> enemyName <> "."
                  tl = resolveSettlementTimeline (cmCatalog m0) tid actorSide targetSide txt pProf eProf pStyle eStyle
                  m1 =
                    pushLog "combat" txt $
                      m0
                        { cmActiveTimeline = Just tl,
                          cmTimelineElapsedMs = 0.0,
                          cmAppliedHits = 1,
                          cmNextTimelineId = tid + 1,
                          cmBattleQueue = rest,
                          cmUiDirty = True
                        }
               in if cmDocHidden m1 then drainImmediately m1 else (m1, [])

commitHitsUpTo :: Double -> ClientModel -> (ClientModel, [ClientCmd])
commitHitsUpTo elapsed m0 =
  case cmActiveTimeline m0 of
    Nothing -> (m0, [])
    Just tl
      | tlKind tl == "settlement" -> (m0, [])
      | otherwise ->
          let hits = tlHits tl
              already = cmAppliedHits m0
              dueIdx = [i | (i, h) <- zip [0 ..] hits, i >= already, elapsed >= rhAtMs h]
           in if null dueIdx
                then (m0, [])
                else
                  let pMax = maybe (psMaxHp (cmStats m0)) (cbMaxHp . bsPlayer) (cmBattleSnap m0)
                      eMax = maybe 180 (cbMaxHp . bsEnemy) (cmBattleSnap m0)
                      applyOne pr idx =
                        let h = hits !! idx
                            dmg = if rhResult h == ResHit then fromMaybe 0 (rhDamage h) else 0
                            hl = fromMaybe 0 (rhHeal h)
                            delta = -dmg + hl
                         in if tlTargetSide tl == SidePlayer
                              then pr {prPlayerHp = max 0 (min pMax (prPlayerHp pr + delta))}
                              else pr {prEnemyHp = max 0 (min eMax (prEnemyHp pr + delta))}
                      pr0 = fromMaybe (PresentationState 100 100 100 100 [] []) (cmPresentation m0)
                      pr1 = foldl' applyOne pr0 dueIdx
                      lastIdx = last dueIdx
                      lastHit = hits !! lastIdx
                      -- On final hit of this timeline, align Qi and Effects if queue is empty
                      prFinal =
                        if lastIdx + 1 >= length hits && null (cmBattleQueue m0)
                          then case cmBattleSnap m0 of
                            Just bs ->
                              pr1
                                { prPlayerQi = cbQi (bsPlayer bs),
                                  prEnemyQi = cbQi (bsEnemy bs),
                                  prPlayerEffects = cbEffects (bsPlayer bs),
                                  prEnemyEffects = cbEffects (bsEnemy bs)
                                }
                            Nothing -> pr1
                          else pr1
                      hitFlashP =
                        if tlTargetSide tl == SidePlayer && rhResult lastHit == ResHit
                          then 220.0
                          else cmPlayerHitFlashMs m0
                      hitFlashE =
                        if tlTargetSide tl == SideEnemy && rhResult lastHit == ResHit
                          then 220.0
                          else cmEnemyHitFlashMs m0
                      w = cmWidth m0
                      hgt = cmHeight m0
                      stageCx = w * 0.5
                      groundY = min (hgt * 0.58) (hgt - 210.0)
                      (cx, cy) = scContact (sampleBattleScene (Just tl) elapsed (raVisual (tlActor tl)) (rtVisual (tlTarget tl)) (cmReducedMotion m0))
                      worldPt = (stageCx + cx * 0.65, groundY + cy)
                      newParts =
                        if cmReducedMotion m0
                          then []
                          else spawnHitParticles worldPt (tlActorSide tl) (rhResult lastHit) (spForce (rhStaging lastHit)) (round (cmClockMs m0) + lastIdx * 31)
                      sfx =
                        if cmSoundOn m0
                          then [CmdPlaySfx (if rhResult lastHit == ResParry then "parry" else if rhResult lastHit == ResHit then "impact" else "whoosh")]
                          else []
                   in ( m0
                          { cmPresentation = Just prFinal,
                            cmAppliedHits = lastIdx + 1,
                            cmPlayerHitFlashMs = hitFlashP,
                            cmEnemyHitFlashMs = hitFlashE,
                            cmParticles = cmParticles m0 <> newParts,
                            cmShockPos = (fst worldPt / max 1.0 w, 1.0 - snd worldPt / max 1.0 hgt),
                            cmShockAge = 0.0,
                            cmShockPower = if cmReducedMotion m0 then 0.0 else spForce (rhStaging lastHit),
                            cmUiDirty = True
                          },
                        sfx
                      )

drainImmediately :: ClientModel -> (ClientModel, [ClientCmd])
drainImmediately m0 =
  case cmActiveTimeline m0 of
    Nothing ->
      if null (cmBattleQueue m0)
        then (m0, [])
        else let (m1, _) = startNextBattleItem m0 in drainImmediately m1
    Just tl ->
      let (m1, _) = commitHitsUpTo (tlDurationMs tl + 1.0) m0
          m2 =
            if tlKind tl == "settlement"
              then m1 {cmActiveTimeline = Nothing, cmInBattle = False, cmPresentation = Nothing, cmUiDirty = True}
              else m1 {cmActiveTimeline = Nothing, cmUiDirty = True}
       in if null (cmBattleQueue m2)
            then (m2, [])
            else let (m3, _) = startNextBattleItem m2 in drainImmediately m3

setDocumentHidden :: Bool -> ClientModel -> ClientModel
setDocumentHidden hidden m0 =
  let m1 = m0 {cmDocHidden = hidden, cmUiDirty = True}
   in if hidden
        then
          let m2 = fst (drainStoryQueue m1)
           in fst (drainImmediately m2)
        else m1

isStorySequencedMsg :: ServerMsg -> Bool
isStorySequencedMsg (SmStory _ _) = True
isStorySequencedMsg (SmDialogue _ _) = True
isStorySequencedMsg (SmStoryTransition _ _) = True
isStorySequencedMsg (SmStorySequence _) = True
isStorySequencedMsg (SmStoryDelay _) = True
isStorySequencedMsg _ = False

drainStoryQueue :: ClientModel -> (ClientModel, [ClientCmd])
drainStoryQueue m0 =
  case cmStoryQueue m0 of
    [] -> (m0 {cmStoryDelayRemMs = 0}, [])
    (sm : rest) ->
      let mPop = m0 {cmStoryQueue = rest, cmStoryDelayRemMs = 0}
          (m1, c1) = case sm of
            SmStoryDelay _ -> (mPop, [])
            _ -> applyServerMessageNow sm mPop
          (m2, c2) = drainStoryQueue m1
       in (m2, c1 <> c2)

stepStoryQueue :: Double -> ClientModel -> (ClientModel, [ClientCmd])
stepStoryQueue dtMs m0
  | cmStoryDelayRemMs m0 <= 0 && null (cmStoryQueue m0) = (m0, [])
  | cmStoryDelayRemMs m0 > dtMs = (m0 {cmStoryDelayRemMs = cmStoryDelayRemMs m0 - dtMs}, [])
  | otherwise = go (m0 {cmStoryDelayRemMs = 0})
  where
    go m = case cmStoryQueue m of
      [] -> (m, [])
      (SmStoryDelay ms : rest) ->
        if ms > 0
          then (m {cmStoryQueue = rest, cmStoryDelayRemMs = fromIntegral ms}, [])
          else go (m {cmStoryQueue = rest})
      (sm : rest) ->
        let (m1, c1) = applyServerMessageNow sm (m {cmStoryQueue = rest})
            (m2, c2) = if cmStoryDelayRemMs m1 > 0 then (m1, []) else go m1
         in (m2, c1 <> c2)

applyServerMessage :: ServerMsg -> ClientModel -> (ClientModel, [ClientCmd])
applyServerMessage msg m0
  | not (cmDocHidden m0)
      && isStorySequencedMsg msg
      && (cmStoryDelayRemMs m0 > 0 || not (null (cmStoryQueue m0))) =
      (m0 {cmStoryQueue = cmStoryQueue m0 <> [msg]}, [])
  | otherwise = applyServerMessageNow msg m0

applyServerMessageNow :: ServerMsg -> ClientModel -> (ClientModel, [ClientCmd])
applyServerMessageNow msg m0 = case msg of
  SmCreationConfig cfg ->
    let defGender = maybe "female" fst (listToMaybe (cfgGenders cfg))
        defOrig = maybe "" coId (listToMaybe (cfgOrigins cfg))
        defC1 = maybe "" coId (listToMaybe (cfgChildhood1 cfg))
        defC2 = maybe "" coId (listToMaybe (cfgChildhood2 cfg))
     in ( m0
            { cmCreationCfg = Just cfg,
              cmCreateChoice = CreationChoice defGender defOrig defC1 defC2,
              cmUiDirty = True
            },
          []
        )
  SmMove dst ->
    let txt = if cmLocale m0 == Zh then "你进入了【" <> dst <> "】。" else "Entered [" <> dst <> "]."
     in (pushLog "move" txt (m0 {cmPanX = 0, cmPanY = 0}), [])
  SmView rName rDesc chars exits ->
    let findInMo mo = (\r -> mo {moCurrentPos = mrPos r}) <$> find (\r -> mrRoomName r == rName) (moRooms mo)
        (nextMo, switchedMap) = case cmMapOverview m0 of
          Just mo -> case findInMo mo of
            Just mo' -> (Just mo', False)
            Nothing ->
              case listToMaybe [mo' | cached <- M.elems (cmMapCache m0), Just mo' <- [findInMo cached]] of
                Just mo' -> (Just mo', True)
                Nothing -> (Just mo, False)
          Nothing ->
            case listToMaybe [mo' | cached <- M.elems (cmMapCache m0), Just mo' <- [findInMo cached]] of
              Just mo' -> (Just mo', True)
              Nothing -> (Nothing, False)
        m1 =
          updateCameraTarget $
            m0
              { cmRoomName = rName,
                cmRoomDesc = rDesc,
                cmRoomChars = chars,
                cmRoomExits = exits,
                cmMapOverview = nextMo,
                cmConnected = True,
                cmConnecting = False,
                cmLastError = Nothing,
                cmSelectedNpc = Nothing,
                cmUiDirty = True
              }
        m2 = if switchedMap then m1 {cmCamX = cmTargetCamX m1, cmCamY = cmTargetCamY m1, cmCamVx = 0, cmCamVy = 0} else m1
        cmds =
          if not (cmRequestedInit m2)
            then
              [ CmdSendWs (encodePlayerAction (ActOther "map")),
                CmdSendWs (encodePlayerAction (ActOther "quests")),
                CmdSendWs (encodePlayerAction (ActOther "inventory")),
                CmdSendWs (encodePlayerAction (ActOther "arts"))
              ]
            else
              -- Only request full map overview if we haven't cached this map yet
              if switchedMap || fmap moMapId nextMo /= fmap moMapId (cmMapOverview m0) || isNothing (nextMo >>= findInMo)
                then [CmdSendWs (encodePlayerAction (ActOther "map"))]
                else []
     in (m2 {cmRequestedInit = True}, cmds)
  SmMapOverview mo ->
    let mapChanged = fmap moMapId (cmMapOverview m0) /= Just (moMapId mo)
        cache' = M.insert (moMapId mo) mo (cmMapCache m0)
        m1 = updateCameraTarget (m0 {cmMapOverview = Just mo, cmMapCache = cache', cmUiDirty = True})
        m2 = if mapChanged then m1 {cmCamX = cmTargetCamX m1, cmCamY = cmTargetCamY m1, cmCamVx = 0, cmCamVy = 0} else m1
     in (m2, [])
  SmAttack atk def ->
    let txt = atk <> (if cmLocale m0 == Zh then " 对 " else " attacks ") <> def <> "！"
        m1 =
          pushLog "combat" txt $
            m0
              { cmInBattle = True,
                cmDesktopDrawer = "",
                cmMobileTab = "world",
                cmSelectedNpc = Nothing,
                cmUiDirty = True
              }
     in (m1, [])
  SmBattleState bs ->
    let p = bsPlayer bs
        e = bsEnemy bs
        idleQueue = isNothing (cmActiveTimeline m0) && null (cmBattleQueue m0)
        fullPres = snapToPresentation bs
        nextPres =
          if idleQueue
            then Just fullPres
            else case cmPresentation m0 of
              Just pr -> Just pr
              Nothing -> Just fullPres
        pRatio = fromIntegral (maybe (cbHp p) prPlayerHp nextPres) / fromIntegral (max 1 (cbMaxHp p))
        eRatio = fromIntegral (maybe (cbHp e) prEnemyHp nextPres) / fromIntegral (max 1 (cbMaxHp e))
        lockUntil = cmClockMs m0 + max 0.0 (bsActionLock bs) * 1000.0
        m1 =
          m0
            { cmInBattle = True,
              cmBattleSnap = Just bs,
              cmCooldownSyncedMs = cmClockMs m0,
              cmActionLockUntilMs = lockUntil,
              cmPresentation = nextPres,
              cmPreEventSnap = Just fullPres,
              cmPlayerHpTrail = max (cmPlayerHpTrail m0) pRatio,
              cmEnemyHpTrail = max (cmEnemyHpTrail m0) eRatio,
              cmPlayerApAnim = cbApProgress p,
              cmEnemyApAnim = cbApProgress e,
              cmUiDirty = True
            }
     in (m1, [])
  SmCombatEvent ev ->
    let preSnap = cmPreEventSnap m0
        mQueued = m0 {cmBattleQueue = cmBattleQueue m0 <> [QCombat ev preSnap], cmInBattle = True}
     in if cmDocHidden mQueued
          then drainImmediately mQueued
          else
            if isJust (cmActiveTimeline mQueued)
              then (mQueued {cmUiDirty = True}, [])
              else startNextBattleItem mQueued
  SmCombatSettlement atk def win ->
    let mQueued = m0 {cmBattleQueue = cmBattleQueue m0 <> [QSettlement atk def win]}
     in if cmDocHidden mQueued
          then drainImmediately mQueued
          else
            if isJust (cmActiveTimeline mQueued)
              then (mQueued {cmUiDirty = True}, [])
              else startNextBattleItem mQueued
  SmActiveSkillFailure reason ->
    let loc = cmLocale m0
        txt = case reason of
          FailNeedAp req cur ->
            if loc == Zh
              then "行动不足：需要 " <> T.pack (show req) <> "，当前 " <> T.pack (show cur) <> "。"
              else "Need " <> T.pack (show req) <> " AP."
          FailNeedQi req cur ->
            trParams loc "error.not_enough_qi" [("required", T.pack (show req)), ("current", T.pack (show cur))]
          FailCooldown s ->
            if loc == Zh then "招式仍在冷却，还需 " <> T.pack (show s) <> " 秒。" else "On cooldown: " <> T.pack (show s) <> "s."
          FailMissingStatus sts ->
            (if loc == Zh then "缺少前置状态：" else "Missing status: ") <> T.intercalate "、" sts
          FailUnavailable sid ->
            (if loc == Zh then "当前无法施展：" else "Unavailable: ") <> sid
     in (pushLog "error" txt m0, [])
  SmDialogue who txt ->
    (pushLog "dialogue" (who <> "：「" <> txt <> "」") m0, [])
  SmStory speaker txt ->
    let pre = if T.null speaker then "" else "【" <> speaker <> "】"
     in (pushLog "story" (pre <> txt) m0, [])
  SmStorySequence active ->
    (m0 {cmStoryActive = active, cmUiDirty = True}, [])
  SmStoryDelay ms ->
    if cmDocHidden m0 || ms <= 0
      then (m0, [])
      else (m0 {cmStoryDelayRemMs = fromIntegral ms}, [])
  SmStoryTransition txt durMs ->
    ( pushLog "story" ("—— " <> txt <> " ——") $
        m0 {cmTransitionBanner = Just (txt, fromIntegral (max 800 durMs)), cmUiDirty = True},
      []
    )
  SmSay who txt ->
    (pushLog "say" (who <> "：「" <> txt <> "」") m0, [])
  SmUseItem _ txt ->
    (pushLog "reward" txt m0, [])
  SmPlayerStats st ->
    let shouldExitBattle =
          psStatus st /= "in_battle"
            && cmPage m0 == PageGame
            && isNothing (cmActiveTimeline m0)
            && null (cmBattleQueue m0)
        m1 =
          m0
            { cmStats = st,
              cmStatsSyncedAtMs = cmClockMs m0,
              cmConnected = True,
              cmConnecting = False,
              cmInBattle = if shouldExitBattle then False else cmInBattle m0,
              cmUiDirty = True
            }
     in (m1, [])
  SmInventory money items ->
    (m0 {cmMoney = money, cmInventory = items, cmUiDirty = True}, [])
  SmArts arts ->
    (m0 {cmArts = arts, cmUiDirty = True}, [])
  SmQuests qs ->
    (m0 {cmQuests = qs, cmUiDirty = True}, [])
  SmReward rs ->
    let fmt r = rwName r <> " ×" <> T.pack (show (rwAmount r))
        txt = (if cmLocale m0 == Zh then "获得奖励：" else "Reward: ") <> T.intercalate "、" (map fmt rs)
     in (pushLog "reward" txt m0, [])
  SmSystem code params ->
    (pushLog "system" (formatSystemMsg (cmLocale m0) code params) m0, [])
  SmError code params ->
    let txt = formatErrorMsg (cmLocale m0) code params
     in (pushLog "error" txt (m0 {cmConnecting = False, cmLastError = Just txt, cmUiDirty = True}), [])
  _ -> (m0, [])

isNothing :: Maybe a -> Bool
isNothing Nothing = True
isNothing (Just _) = False

stepClientFrame :: Double -> Double -> Double -> ClientModel -> (ClientModel, [ClientCmd])
stepClientFrame rawDtMs rawW rawH m0 =
  let dtSec = max 0.001 (min 0.25 (rawDtMs / 1000.0))
      dtMs = dtSec * 1000.0
      w = max 320.0 rawW
      h = max 220.0 rawH
      nowMs = cmClockMs m0 + dtMs

      -- Unconditionally stable analytical exponential camera smoothing (immune to large frame hitches)
      camAlpha = if cmReducedMotion m0 then 1.0 else 1.0 - exp (-14.0 * dtSec)
      cx1 = cmCamX m0 + (cmTargetCamX m0 - cmCamX m0) * camAlpha
      cy1 = cmCamY m0 + (cmTargetCamY m0 - cmCamY m0) * camAlpha
      vx1 = 0.0
      vy1 = 0.0

      -- Advance story delay queue
      (mAfterStory, storyCmds) = stepStoryQueue dtMs (m0 {cmWidth = w, cmHeight = h, cmClockMs = nowMs})

      -- Advance active combat timeline
      effDtMs = if cmLabPaused mAfterStory then 0.0 else dtMs * cmLabSpeed mAfterStory
      (mAfterTl, tlCmds) = stepBattleTimeline effDtMs mAfterStory

      -- Trailing damage bars (decay gently after damage commits)
      pCurRatio = case (cmPresentation mAfterTl, cmBattleSnap mAfterTl) of
        (Just pr, Just bs) -> fromIntegral (prPlayerHp pr) / fromIntegral (max 1 (cbMaxHp (bsPlayer bs)))
        _ -> fromIntegral (psHp (cmStats mAfterTl)) / fromIntegral (max 1 (psMaxHp (cmStats mAfterTl)))
      eCurRatio = case (cmPresentation mAfterTl, cmBattleSnap mAfterTl) of
        (Just pr, Just bs) -> fromIntegral (prEnemyHp pr) / fromIntegral (max 1 (cbMaxHp (bsEnemy bs)))
        _ -> 1.0
      stepTrail cur tgt = if cur > tgt then max tgt (cur - dtSec * 0.42) else tgt
      pTrail1 = stepTrail (cmPlayerHpTrail mAfterTl) pCurRatio
      eTrail1 = stepTrail (cmEnemyHpTrail mAfterTl) eCurRatio

      -- AP smooth prediction aligned with backend/master agility formula and action lock
      (pAgi, eAgi) = case cmBattleSnap mAfterTl of
        Just bs -> (fromIntegral (cbAgility (bsPlayer bs)), fromIntegral (cbAgility (bsEnemy bs)))
        Nothing -> (fromIntegral (psAgility (cmStats mAfterTl)), apBaselineAgility)
      canGrowAp =
        cmInBattle mAfterTl
          && not (cmLabPaused mAfterTl)
          && isNothing (cmActiveTimeline mAfterTl)
          && nowMs >= cmActionLockUntilMs mAfterTl
      stepAp cur agi =
        if canGrowAp
          then if cur >= 99.9 then 100.0 else min 99.0 (cur + max 1.0 agi * apGainPerAgilitySecond * dtSec)
          else cur
      pAp1 = stepAp (cmPlayerApAnim mAfterTl) pAgi
      eAp1 = stepAp (cmEnemyApAnim mAfterTl) eAgi

      -- Hit flash decay
      pFlash1 = max 0.0 (cmPlayerHitFlashMs mAfterTl - dtMs)
      eFlash1 = max 0.0 (cmEnemyHitFlashMs mAfterTl - dtMs)
      flashEnded =
        (cmPlayerHitFlashMs mAfterTl > 0 && pFlash1 <= 0)
          || (cmEnemyHitFlashMs mAfterTl > 0 && eFlash1 <= 0)

      -- Transition banner decay
      nextBanner = case cmTransitionBanner mAfterTl of
        Nothing -> Nothing
        Just (txt, remMs) ->
          let r' = remMs - dtMs
           in if r' <= 0 then Nothing else Just (txt, r')

      -- Step particles
      stepPart p =
        p
          { ipX = ipX p + ipVx p * dtSec,
            ipY = ipY p + ipVy p * dtSec,
            ipVx = ipVx p * (1.0 - 3.2 * dtSec),
            ipVy = ipVy p + 340.0 * dtSec,
            ipLife = ipLife p + dtSec
          }
      liveParts = filter (\p -> ipLife p < ipMaxLife p) (map stepPart (cmParticles mAfterTl))

      -- Periodic lightweight HUD sync for live cooldowns, AP, HP trail, buffs, training progress & injury countdown
      hasLiveTimers =
        cmInBattle mAfterTl
          || isJust (psBusy (cmStats mAfterTl))
          || psInjuredSeconds (cmStats mAfterTl) > 0
      syncIntervalMs = if cmInBattle mAfterTl then 80.0 else 180.0
      tickSyncDue = hasLiveTimers && (nowMs - cmLastSyncTickMs mAfterTl >= syncIntervalMs)
      nextSyncTick = if tickSyncDue then nowMs else cmLastSyncTickMs mAfterTl

      bannerChanged = isJust (cmTransitionBanner mAfterTl) /= isJust nextBanner
   in ( mAfterTl
          { cmCamX = cx1,
            cmCamY = cy1,
            cmCamVx = vx1,
            cmCamVy = vy1,
            cmLastSyncTickMs = nextSyncTick,
            cmPlayerHpTrail = pTrail1,
            cmEnemyHpTrail = eTrail1,
            cmPlayerApAnim = pAp1,
            cmEnemyApAnim = eAp1,
            cmPlayerHitFlashMs = pFlash1,
            cmEnemyHitFlashMs = eFlash1,
            cmTransitionBanner = nextBanner,
            cmParticles = liveParts,
            cmShockAge = min 99.0 (cmShockAge mAfterTl + dtSec),
            cmUiDirty = cmUiDirty mAfterTl || bannerChanged || flashEnded || tickSyncDue
          },
        storyCmds <> tlCmds
      )

stepBattleTimeline :: Double -> ClientModel -> (ClientModel, [ClientCmd])
stepBattleTimeline stepMs m0 =
  case cmActiveTimeline m0 of
    Nothing -> (m0, [])
    Just tl ->
      let nextElapsed = cmTimelineElapsedMs m0 + stepMs
          (m1, hitCmds) = commitHitsUpTo nextElapsed (m0 {cmTimelineElapsedMs = min (tlDurationMs tl) nextElapsed})
       in if nextElapsed < tlDurationMs tl
            then (m1, hitCmds)
            else
              if tlKind tl == "settlement"
                then
                  let mDone =
                        m1
                          { cmActiveTimeline = Nothing,
                            cmTimelineElapsedMs = 0.0,
                            cmInBattle = False,
                            cmBattleSnap = Nothing,
                            cmPresentation = Nothing,
                            cmUiDirty = True
                          }
                      endCmds = if cmPage mDone == PageGame then [CmdSendWs (encodePlayerAction (ActOther "view"))] else []
                   in (mDone, hitCmds <> endCmds)
                else
                  let (mNext, nextCmds) = startNextBattleItem (m1 {cmActiveTimeline = Nothing, cmTimelineElapsedMs = 0.0})
                   in (mNext, hitCmds <> nextCmds)

-- Pointer, Scroll, IME, Keyboard & Camera Controls

findHit :: Double -> Double -> [CanvasHitbox] -> Maybe CanvasHitbox
findHit x y =
  listToMaybe
    . filter (\hb -> x >= chX hb && x <= chX hb + chW hb && y >= chY hb && y <= chY hb + chH hb)
    . reverse

findScrollZone :: Double -> Double -> [ScrollZone] -> Maybe ScrollTarget
findScrollZone x y =
  fmap szTarget
    . listToMaybe
    . filter (\sz -> x >= szX sz && x <= szX sz + szW sz && y >= szY sz && y <= szY sz + szH sz)
    . reverse

handlePointerMove :: Double -> Double -> ClientModel -> (ClientModel, [ClientCmd])
handlePointerMove x y m =
  let mHit = findHit x y (cmHitboxes m)
      nextTarget = fmap chTarget mHit
      cursor = maybe "default" chCursor mHit
      cmds = if nextTarget /= cmHovered m then [CmdSetCursor cursor] else []
   in (m {cmHovered = nextTarget}, cmds)

handlePointerClick :: Double -> Double -> ClientModel -> (ClientModel, [ClientCmd])
handlePointerClick x y m0 =
  case findHit x y (cmHitboxes m0) of
    Nothing ->
      if isJust (cmFocusedInput m0)
        then (m0 {cmFocusedInput = Nothing}, [CmdBlurInput])
        else (m0, [])
    Just hb ->
      let blurIfOther targetInput =
            if cmFocusedInput m0 /= targetInput && isJust (cmFocusedInput m0)
              then (m0 {cmFocusedInput = Nothing}, [CmdBlurInput])
              else (m0, [])
       in case chTarget hb of
            HitSwallow ->
              blurIfOther Nothing
            HitFocusInput inpId ->
              let curVal = if inpId == "login" then cmUsername m0 else cmSayDraft m0
               in ( m0 {cmFocusedInput = Just inpId},
                    [CmdFocusInput inpId curVal (chX hb) (chY hb) (chW hb) (chH hb)]
                  )
            HitExit dir ->
              let (m1, bc) = blurIfOther Nothing
               in if cmConnected m1 && not (cmStoryActive m1)
                    then (m1, bc <> [CmdSendWs (encodePlayerAction (ActGo dir))])
                    else (m1, bc)
            HitNpc cid ->
              let (m1, bc) = blurIfOther Nothing
                  nextSel = if cmSelectedNpc m1 == Just cid then Nothing else Just cid
               in (m1 {cmSelectedNpc = nextSel, cmNpcScroll = 0, cmUiDirty = True}, bc)
            HitResetCam ->
              let (m1, bc) = blurIfOther Nothing
               in (resetCameraPan m1, bc)
            HitUi k a1 a2 ->
              let (m1, bc) = blurIfOther Nothing
                  (m2, ucs) = handleUiAction k a1 a2 m1
               in (m2, bc <> ucs)
            HitLab cmd a1 a2 a3 num ->
              let (m1, bc) = blurIfOther Nothing
                  (m2, lcs) = handleLabCommand cmd a1 a2 a3 num m1
               in (m2, bc <> lcs)
            HitLabScrub x0 w0 ->
              let (m1, bc) = blurIfOther Nothing
                  ratio = max 0.0 (min 1.0 ((x - x0) / max 1.0 w0))
                  dur = maybe 0.0 tlDurationMs (cmActiveTimeline m1)
                  (m2, l1) = handleLabCommand "pause" "true" "" "" 0 m1
                  (m3, l2) = handleLabCommand "seek" "" "" "" (ratio * dur) m2
               in (m3, bc <> l1 <> l2)

applyScrollDelta :: ScrollTarget -> Double -> ClientModel -> ClientModel
applyScrollDelta tgt deltaY m = case tgt of
  ScrollLog ->
    let maxS = cmLogMaxScroll m
        cur = if cmLogStickBottom m then maxS else cmLogScroll m
        next = max 0.0 (min maxS (cur + deltaY))
        stick = maxS <= 1.0 || (maxS - next) <= 22.0
     in m {cmLogScroll = next, cmLogStickBottom = stick}
  ScrollDrawer ->
    let next = max 0.0 (min (cmDrawerMaxScroll m) (cmDrawerScroll m + deltaY))
     in m {cmDrawerScroll = next}
  ScrollOnboard ->
    let next = max 0.0 (min (cmOnboardMaxScroll m) (cmOnboardScroll m + deltaY))
     in m {cmOnboardScroll = next}
  ScrollNpc ->
    let next = max 0.0 (min (cmNpcMaxScroll m) (cmNpcScroll m + deltaY))
     in m {cmNpcScroll = next}

handleScrollAt :: Double -> Double -> Double -> ClientModel -> ClientModel
handleScrollAt x y deltaY m =
  case findScrollZone x y (cmScrollZones m) of
    Just tgt -> applyScrollDelta tgt deltaY m
    Nothing ->
      let factor = if deltaY < 0 then 1.09 else 0.92
       in zoomCameraBy factor m

handleDragAt :: Double -> Double -> Double -> Double -> ClientModel -> ClientModel
handleDragAt x y dx dy m =
  case findHit x y (cmHitboxes m) of
    Just hb | HitLabScrub x0 w0 <- chTarget hb ->
      let ratio = max 0.0 (min 1.0 ((x - x0) / max 1.0 w0))
          dur = maybe 0.0 tlDurationMs (cmActiveTimeline m)
          (m1, _) = handleLabCommand "pause" "true" "" "" 0 m
          (m2, _) = handleLabCommand "seek" "" "" "" (ratio * dur) m1
       in m2
    _ ->
      case findScrollZone x y (cmScrollZones m) of
        Just tgt -> applyScrollDelta tgt (-dy) m
        Nothing -> panCameraBy dx dy m

handleTextInput :: Text -> Text -> ClientModel -> ClientModel
handleTextInput inpId val m = case inpId of
  "login" -> m {cmUsername = val}
  "say" -> m {cmSayDraft = val}
  _ -> m

handleTextSubmit :: Text -> ClientModel -> (ClientModel, [ClientCmd])
handleTextSubmit inpId m0 = case inpId of
  "login" ->
    let m1 = m0 {cmFocusedInput = Nothing}
     in if cmLoginMode m1 == "create"
          then
            let (m2, cs) = handleUiAction "create_step" "1" "" m1
             in (m2, CmdBlurInput : cs)
          else
            let passFlag = if cmDevReset m1 then "reset" else ""
                (m2, cs) = handleUiAction "login_submit" (cmUsername m1) passFlag m1
             in (m2, CmdBlurInput : cs)
  "say" ->
    let txt = T.strip (cmSayDraft m0)
        m1 = m0 {cmSayDraft = "", cmFocusedInput = Nothing, cmLogStickBottom = True}
     in if T.null txt
          then (m1, [CmdBlurInput])
          else (m1, [CmdBlurInput, CmdSendWs (encodePlayerAction (ActSay txt))])
  _ -> (m0, [])

handleFocusInputId :: Text -> ClientModel -> ClientModel
handleFocusInputId inpId m = m {cmFocusedInput = if T.null inpId then Nothing else Just inpId}

handleBlurInput :: ClientModel -> ClientModel
handleBlurInput m = m {cmFocusedInput = Nothing}

handleKeyDown :: Text -> ClientModel -> (ClientModel, [ClientCmd])
handleKeyDown key m0
  | isJust (cmFocusedInput m0) =
      if key == "Escape"
        then (m0 {cmFocusedInput = Nothing}, [CmdBlurInput])
        else (m0, [])
  | key == "Escape" =
      (m0 {cmDesktopDrawer = "", cmSelectedNpc = Nothing, cmUiDirty = True}, [])
  | cmInBattle m0 =
      case key of
        "1" -> handleUiAction "perform_index" "0" "" m0
        "2" -> handleUiAction "perform_index" "1" "" m0
        "3" -> handleUiAction "perform_index" "2" "" m0
        "4" -> handleUiAction "perform_index" "3" "" m0
        "5" -> handleUiAction "perform_index" "4" "" m0
        "6" -> handleUiAction "perform_index" "5" "" m0
        _ -> (m0, [])
  | cmConnected m0 && not (cmStoryActive m0) && T.null (cmDesktopDrawer m0) && isNothing (cmSelectedNpc m0) =
      let mDir = case key of
            "ArrowUp" -> Just North
            "w" -> Just North
            "W" -> Just North
            "ArrowDown" -> Just South
            "s" -> Just South
            "S" -> Just South
            "ArrowLeft" -> Just West
            "a" -> Just West
            "A" -> Just West
            "ArrowRight" -> Just East
            "d" -> Just East
            "D" -> Just East
            _ -> Nothing
       in case mDir of
            Just dir | any (\ex -> reDirection ex == dir) (cmRoomExits m0) ->
              (m0, [CmdSendWs (encodePlayerAction (ActGo dir))])
            _ -> (m0, [])
  | otherwise = (m0, [])

isCameraPanned :: ClientModel -> Bool
isCameraPanned m =
  abs (cmPanX m) > 6.0 || abs (cmPanY m) > 6.0 || abs (cmMapZoom m - 1.0) > 0.04

panCameraBy :: Double -> Double -> ClientModel -> ClientModel
panCameraBy dx dy m
  | cmInBattle m || cmPage m /= PageGame = m
  | otherwise =
      let m1 = m {cmPanX = max (-900) (min 900 (cmPanX m + dx)), cmPanY = max (-700) (min 700 (cmPanY m + dy))}
       in if isCameraPanned m1 /= isCameraPanned m then m1 {cmUiDirty = True} else m1

zoomCameraBy :: Double -> ClientModel -> ClientModel
zoomCameraBy factor m
  | cmInBattle m || cmPage m /= PageGame = m
  | otherwise =
      let m1 = m {cmMapZoom = max 0.58 (min 1.75 (cmMapZoom m * factor))}
       in if isCameraPanned m1 /= isCameraPanned m then m1 {cmUiDirty = True} else m1

resetCameraPan :: ClientModel -> ClientModel
resetCameraPan m = m {cmPanX = 0, cmPanY = 0, cmMapZoom = 1.0, cmUiDirty = True}

-- UI Actions

handleUiAction :: Text -> Text -> Text -> ClientModel -> (ClientModel, [ClientCmd])
handleUiAction kind a1 a2 m0 = case kind of
  "reset_cam" ->
    (resetCameraPan m0, [])
  "zoom_in" ->
    (zoomCameraBy 1.18 m0, [])
  "zoom_out" ->
    (zoomCameraBy 0.85 m0, [])
  "close_all" ->
    (m0 {cmDesktopDrawer = "", cmSelectedNpc = Nothing, cmUiDirty = True}, [])
  "toggle_dev_reset" ->
    (m0 {cmDevReset = not (cmDevReset m0), cmUiDirty = True}, [])
  "scroll_log_bottom" ->
    (m0 {cmLogStickBottom = True, cmLogScroll = cmLogMaxScroll m0}, [])
  "send_say_draft" ->
    handleTextSubmit "say" m0
  "lab_cycle_action" ->
    let acts = labActionOrder m0
        n = max 1 (length acts)
        step = if a1 == "prev" then -1 else 1
        idx' = (cmLabActionIdx m0 + step + n) `mod` n
     in (m0 {cmLabActionIdx = idx'}, [])
  "lab_cycle_outcome" ->
    (m0 {cmLabOutcomeIdx = (cmLabOutcomeIdx m0 + 1) `mod` 4}, [])
  "lab_cycle_side" ->
    (m0 {cmLabSideIdx = (cmLabSideIdx m0 + 1) `mod` 2}, [])
  "lab_play_selected" ->
    let acts = labActionOrder m0
        aid = if null acts then "rig.fist.punch_a" else acts !! (cmLabActionIdx m0 `mod` length acts)
        out = ["hit", "dodge", "parry", "effect"] !! (cmLabOutcomeIdx m0 `mod` 4)
        side = ["player", "enemy"] !! (cmLabSideIdx m0 `mod` 2)
        (m1, c1) = handleLabCommand "seed" "female" "male" "" 0 m0
        (m2, c2) = handleLabCommand "submit" aid out side 18 m1
     in (m2, c1 <> c2)
  "toggle_look" ->
    let lk = if cmLookStyle m0 == LookMaiden then LookPonytail else LookMaiden
     in (m0 {cmLookStyle = lk, cmUiDirty = True}, [])
  "request_creation_cfg" ->
    (m0, [CmdOpenConfigWs])
  "set_locale" ->
    (m0 {cmLocale = parseLocale a1, cmUiDirty = True}, [])
  "toggle_locale" ->
    let next = if cmLocale m0 == Zh then En else Zh
     in (m0 {cmLocale = next, cmUiDirty = True}, [])
  "toggle_sound" ->
    (m0 {cmSoundOn = not (cmSoundOn m0), cmUiDirty = True}, [])
  "set_look" ->
    let lk = if a1 == "ponytail" then LookPonytail else LookMaiden
     in (m0 {cmLookStyle = lk, cmUiDirty = True}, [])
  "login_mode" ->
    let cmds = if a1 == "create" && isNothing (cmCreationCfg m0) then [CmdOpenConfigWs] else []
     in (m0 {cmLoginMode = a1, cmLastError = Nothing, cmUiDirty = True}, cmds)
  "set_username" ->
    (m0 {cmUsername = a1, cmUiDirty = True}, [])
  "create_step" ->
    let stp = maybe 0 fst (listToMaybe (reads (T.unpack a1) :: [(Int, String)]))
     in (m0 {cmCreateStep = max 0 (min 5 stp), cmUiDirty = True}, [])
  "create_pick" ->
    let cc = cmCreateChoice m0
        cc' = case a1 of
          "gender" -> cc {ccGender = a2}
          "origin" -> cc {ccOrigin = a2}
          "childhood1" -> cc {ccChildhood1 = a2}
          "childhood2" -> cc {ccChildhood2 = a2}
          _ -> cc
        nextStep = min 5 (cmCreateStep m0 + 1)
     in (m0 {cmCreateChoice = cc', cmCreateStep = nextStep, cmUiDirty = True}, [])
  "login_submit" ->
    let u = T.strip a1
        pass = if a2 == "reset" then "__dev_reset" else ""
     in if T.null u
          then (m0 {cmLastError = Just (tr (cmLocale m0) "error.username_required"), cmUiDirty = True}, [])
          else
            ( m0 {cmUsername = u, cmConnecting = True, cmLastError = Nothing, cmRequestedInit = False, cmUiDirty = True},
              [CmdSaveLocal "tingfeng.lastUsername" u, CmdConnectWs u pass Nothing]
            )
  "create_submit" ->
    let u = T.strip a1
        pass = if a2 == "reset" then "__dev_reset" else ""
     in if T.null u
          then (m0 {cmCreateStep = 0, cmLastError = Just (tr (cmLocale m0) "error.username_required"), cmUiDirty = True}, [])
          else
            ( m0 {cmUsername = u, cmConnecting = True, cmLastError = Nothing, cmRequestedInit = False, cmUiDirty = True},
              [CmdSaveLocal "tingfeng.lastUsername" u, CmdConnectWs u pass (Just (cmCreateChoice m0))]
            )
  "desktop_drawer" ->
    let next = if cmDesktopDrawer m0 == a1 then "" else a1
     in (m0 {cmDesktopDrawer = next, cmDrawerScroll = 0, cmUiDirty = True}, [])
  "char_subtab" ->
    (m0 {cmCharSubTab = a1, cmDrawerScroll = 0, cmUiDirty = True}, [])
  "mobile_tab" ->
    let unread = if a1 == "log" then 0 else cmUnreadLogs m0
     in (m0 {cmMobileTab = a1, cmUnreadLogs = unread, cmDrawerScroll = 0, cmUiDirty = True}, [])
  "select_npc" ->
    let next = if T.null a1 || cmSelectedNpc m0 == Just a1 then Nothing else Just a1
     in (m0 {cmSelectedNpc = next, cmNpcScroll = 0, cmUiDirty = True}, [])
  "go" ->
    case parseDirection a1 of
      Just d -> (m0, [CmdSendWs (encodePlayerAction (ActGo d))])
      Nothing -> (m0, [])
  "talk" ->
    (m0 {cmSelectedNpc = Nothing, cmUiDirty = True}, [CmdSendWs (encodePlayerAction (ActTalk a1))])
  "attack" ->
    (m0 {cmSelectedNpc = Nothing, cmUiDirty = True}, [CmdSendWs (encodePlayerAction (ActAttack a1))])
  "learn" ->
    let n = maybe 1 fst (listToMaybe (reads (T.unpack a2) :: [(Int, String)]))
     in case T.splitOn ":" a1 of
          [tid, aid] -> (m0, [CmdSendWs (encodePlayerAction (ActLearn tid aid n))])
          _ -> (m0, [])
  "buy" ->
    case T.splitOn ":" a1 of
      [merch, iid] -> (m0, [CmdSendWs (encodePlayerAction (ActBuy (if T.null merch then Nothing else Just merch) iid))])
      _ -> (m0, [CmdSendWs (encodePlayerAction (ActBuy Nothing a1))])
  "perform" ->
    (m0, [CmdSendWs (encodePlayerAction (ActPerform a1))])
  "perform_index" ->
    let idx = maybe (-1) fst (listToMaybe (reads (T.unpack a1) :: [(Int, String)]))
        skills = maybe [] bsActiveSkills (cmBattleSnap m0)
     in if idx >= 0 && idx < length skills
          then (m0, [CmdSendWs (encodePlayerAction (ActPerform (asId (skills !! idx))))])
          else (m0, [])
  "practice" ->
    let n = maybe 1 fst (listToMaybe (reads (T.unpack a2) :: [(Int, String)]))
     in (m0, [CmdSendWs (encodePlayerAction (ActPractice a1 n))])
  "research" ->
    (m0, [CmdSendWs (encodePlayerAction (ActResearch a1 1))])
  "enable" ->
    (m0, [CmdSendWs (encodePlayerAction (ActEnable a1 a2))])
  "meditate" ->
    (m0, [CmdSendWs (encodePlayerAction (ActMeditate 20 10))])
  "halt" ->
    (m0, [CmdSendWs (encodePlayerAction (ActOther "halt"))])
  "use" ->
    (m0, [CmdSendWs (encodePlayerAction (ActUse a1))])
  "study" ->
    (m0, [CmdSendWs (encodePlayerAction (ActStudy a1 10))])
  "refresh" ->
    ( m0,
      [ CmdSendWs (encodePlayerAction (ActOther "view")),
        CmdSendWs (encodePlayerAction (ActOther "quests")),
        CmdSendWs (encodePlayerAction (ActOther "inventory")),
        CmdSendWs (encodePlayerAction (ActOther "arts"))
      ]
    )
  "say" ->
    let s = T.strip a1
     in if T.null s then (m0, []) else (m0, [CmdSendWs (encodePlayerAction (ActSay s))])
  "clear_logs" ->
    (m0 {cmLogs = [], cmUnreadLogs = 0, cmUiDirty = True}, [])
  "set_reduced_motion" ->
    (m0 {cmReducedMotion = a1 == "1", cmUiDirty = True}, [])
  _ -> (m0, [])

-- BattleLab & Fixtures Commands (100% compatible with tests/battle.spec.ts!)

labCombatant :: Text -> Text -> Text -> CombatantInfo
labCombatant name style gender =
  CombatantInfo name name gender style 180 180 100 100 100 100.0 18 []

handleLabCommand :: Text -> Text -> Text -> Text -> Double -> ClientModel -> (ClientModel, [ClientCmd])
handleLabCommand cmd a1 a2 a3 numArg m0 = case cmd of
  "seed" ->
    let pGender = if T.null a1 then "female" else a1
        eGender = if T.null a2 then "male" else a2
        snap = BattleSnap (labCombatant "行者" "fist" pGender) (labCombatant "守擂人" "sword" eGender) M.empty [] 0 Nothing
        mReset =
          m0
            { cmConnected = True,
              cmUsername = "行者",
              cmStats = (cmStats m0) {psGender = pGender, psHp = 180, psMaxHp = 180},
              cmRoomName = "竹间试招",
              cmLogs = [],
              cmActiveTimeline = Nothing,
              cmTimelineElapsedMs = 0,
              cmAppliedHits = 0,
              cmBattleQueue = [],
              cmPresentation = Nothing,
              cmPreEventSnap = Nothing,
              cmLabPaused = False,
              cmLabSpeed = 1.0,
              cmUiDirty = True
            }
     in applyServerMessage (SmBattleState snap) mReset
  "submit" ->
    let aid = if T.null a1 then "rig.fist.punch_a" else a1
        res = parseCombatResult (if T.null a2 then "hit" else a2)
        side = parseBattleSide (if T.null a3 then "player" else a3)
        dmg = if numArg <= 0 then 18 else round numArg
        act = battleActionFor (cmCatalog m0) aid StyleFist
        bs0 = fromMaybe (BattleSnap (labCombatant "行者" "fist" "female") (labCombatant "守擂人" "sword" "male") M.empty [] 0 Nothing) (cmBattleSnap m0)
        isSelf = adActorMotion act == "focus"
        isEff = "rig.effect." `T.isPrefixOf` aid
        stTxt = combatStyleText (adStyle act)
        pl0 = if side == SidePlayer && not isEff then (bsPlayer bs0) {cbStyle = stTxt} else bsPlayer bs0
        en0 = if side == SideEnemy && not isEff then (bsEnemy bs0) {cbStyle = stTxt} else bsEnemy bs0
        actorC = if side == SidePlayer then pl0 else en0
        targetIsPlayer = if isSelf then side == SidePlayer else side == SideEnemy
        targetC = if targetIsPlayer then pl0 else en0
        snapBefore = bs0 {bsPlayer = pl0, bsEnemy = en0, bsActionLock = adDurationMs act / 1000.0}
        (m1, c1) = applyServerMessage (SmBattleState snapBefore) m0
        mHeal = if "healing" `T.isInfixOf` aid || "hot" `T.isSuffixOf` aid then Just 22 else Nothing
        mDmg = if res == ResHit && isNothing mHeal then Just dmg else Nothing
        evKind = if isEff then "effect_tick" else if isSelf then "active_skill" else "normal"
        evRes = if isSelf || isJust mHeal then ResEffect else res
        ev = CombatEvt evKind (cbName actorC) (cbName targetC) "script" (adLabel act) "" 0 mDmg mHeal evRes [] aid (adTags act) Nothing (Just (adDurationMs act)) Nothing
        (m2, c2) = applyServerMessage (SmCombatEvent ev) m1
        hpDelta = -fromMaybe 0 mDmg + fromMaybe 0 mHeal
        updTarget cb = cb {cbHp = max 0 (min (cbMaxHp cb) (cbHp cb + hpDelta))}
        snapAfter =
          if targetIsPlayer
            then snapBefore {bsPlayer = updTarget pl0}
            else snapBefore {bsEnemy = updTarget en0}
        (m3, c3) = applyServerMessage (SmBattleState snapAfter) m2
     in (m3, c1 <> c2 <> c3)
  "demo" ->
    let steps =
          [ ("rig.fist.punch_a", "hit", "player", 18),
            ("rig.fist.punch_a", "hit", "player", 18),
            ("rig.sword.thrust_a", "parry", "enemy", 18),
            ("rig.fist.kick_a", "dodge", "player", 18),
            ("rig.sword.cut_a", "hit", "enemy", 26),
            ("rig.fist.heavy_a", "hit", "player", 35),
            ("rig.fist.healing_palm", "effect", "player", 0),
            ("rig.sword.rising_cut_a", "dodge", "enemy", 18),
            ("rig.fist.heavy_a", "hit", "player", 109)
          ]
        (mSeed, c0) = handleLabCommand "seed" "female" "male" "" 0 m0
        (mMid, cMid) =
          foldl'
            ( \(accM, accC) (aid, r, s, d) ->
                let (nm, nc) = handleLabCommand "submit" aid r s d accM
                 in (nm, accC <> nc)
            )
            (mSeed, c0)
            steps
        (mEnd, cEnd) = applyServerMessage (SmCombatSettlement "行者" "守擂人" True) mMid
     in (mEnd, cMid <> cEnd)
  "pause" ->
    let paused = a1 /= "false" && a1 /= "0"
     in (m0 {cmLabPaused = paused, cmUiDirty = True}, [])
  "speed" ->
    (m0 {cmLabSpeed = max 0.05 (min 4.0 numArg), cmUiDirty = True}, [])
  "seek" ->
    case cmActiveTimeline m0 of
      Nothing -> (m0, [])
      Just tl ->
        let clamped = max 0.0 (min (tlDurationMs tl) numArg)
            (m1, sfx) = commitHitsUpTo clamped (m0 {cmTimelineElapsedMs = clamped, cmUiDirty = True})
         in (m1, sfx)
  _ -> (m0, [])

-- Helpers shared with full-canvas UI renderer & Playwright battle lab state probe

labActionOrder :: ClientModel -> [Text]
labActionOrder m =
  [ aid
    | aid <- acOrder (cmCatalog m),
      Just act <- [M.lookup aid (acActions (cmCatalog m))],
      isTravelMotion (adActorMotion act) || adActorMotion act == "focus" || "rig.effect." `T.isPrefixOf` aid
  ]

liveEffectsOf :: ClientModel -> Bool -> [(EffectInfo, Double)]
liveEffectsOf m isPlayer =
  let cdAgeSec = max 0.0 ((cmClockMs m - cmCooldownSyncedMs m) / 1000.0)
      raw = case (cmPresentation m, cmBattleSnap m) of
        (Just pr, _) -> if isPlayer then prPlayerEffects pr else prEnemyEffects pr
        (Nothing, Just bs) -> if isPlayer then cbEffects (bsPlayer bs) else cbEffects (bsEnemy bs)
        _ -> []
   in [ (ef, remS)
        | ef <- raw,
          let remS = max 0.0 (efRemaining ef - cdAgeSec),
          remS > 0.05
      ]

data SkillEval = SkillEval
  { seSkill :: !ActiveSkillInfo,
    seCdRem :: !Double,
    seCdTotal :: !Double,
    seReady :: !Bool,
    seQueued :: !Bool,
    seUltimate :: !Bool,
    seReason :: !Text
  }
  deriving (Show, Eq)

evalSkillState :: ClientModel -> [SkillEval]
evalSkillState m = case cmBattleSnap m of
  Nothing -> []
  Just bs ->
    let loc = cmLocale m
        cdAgeSec = max 0.0 ((cmClockMs m - cmCooldownSyncedMs m) / 1000.0)
        cds = bsCooldowns bs
        pEffs = liveEffectsOf m True
        presQi = case cmPresentation m of
          Just pr -> prPlayerQi pr
          Nothing -> cbQi (bsPlayer bs)
        apCur = max (cbAp (bsPlayer bs)) (floor (cmPlayerApAnim m))
     in [ let cdRem = max 0.0 (fromMaybe 0.0 (M.lookup (asId sk) cds) - cdAgeSec)
              missingReqs =
                [ nm
                  | (reqId, nm) <- zip (asReqStatus sk) (asReqStatusNames sk <> repeat ""),
                    not (any (\(ef, _) -> efId ef == reqId) pEffs)
                ]
              hasReqs = null missingReqs
              ready = cdRem <= 0.05 && presQi >= asCost sk && apCur >= asApReq sk && hasReqs
              queued = bsPendingSkillId bs == Just (asId sk)
              reasonTxt
                | queued = if loc == Zh then "蓄势待发" else "Queued"
                | cdRem > 0.05 = (if loc == Zh then "冷却 " else "CD ") <> T.pack (show (ceiling cdRem :: Int)) <> "s"
                | not hasReqs = (if loc == Zh then "需「" else "Need ") <> T.intercalate "、" (filter (not . T.null) missingReqs) <> (if loc == Zh then "」" else "")
                | presQi < asCost sk = (if loc == Zh then "需气 " else "Qi ") <> T.pack (show (asCost sk))
                | apCur < asApReq sk = (if loc == Zh then "需动 " else "AP ") <> T.pack (show (asApReq sk))
                | otherwise = (if loc == Zh then "动 " else "AP ") <> T.pack (show (asApReq sk)) <> (if loc == Zh then " · 气 " else " · Qi ") <> T.pack (show (asCost sk))
           in SkillEval
                { seSkill = sk,
                  seCdRem = cdRem,
                  seCdTotal = max 1.0 (asCooldown sk),
                  seReady = ready,
                  seQueued = queued,
                  seUltimate = fromMaybe 0 (asDamage sk) >= 100,
                  seReason = reasonTxt
                }
          | sk <- bsActiveSkills bs
        ]

portraitScoreFile :: Text -> Int -> Text -> Text
portraitScoreFile gender app playerName =
  let evenScore = max 0 (min 10 (((app + 1) `div` 2) * 2))
      twoDigit = if evenScore < 10 then "0" <> T.pack (show evenScore) else T.pack (show evenScore)
      variant = 1 + T.foldl' (\acc ch -> (acc * 31 + fromEnum ch) `mod` 4) 0 (T.strip playerName)
      variantText = "-0" <> T.pack (show variant)
      version = if evenScore >= 8 then "v9" else "v8"
      portraitGender = case gender of
        "female" -> "female"
        "male" -> "male"
        -- Old saves without a gender used male-looking 0/2 and female-looking
        -- 4/6/8/10 portraits. Preserve that fallback while using the new style.
        _ -> if evenScore <= 2 then "male" else "female"
   in "beauty-" <> version <> "-" <> portraitGender <> "-" <> twoDigit <> variantText

buildLabStateJson :: ClientModel -> Text
buildLabStateJson m =
  let mTl = cmActiveTimeline m
      tlVal = case mTl of
        Nothing -> JNull
        Just tl ->
          jObj
            [ "id" .= JNum (fromIntegral (tlId tl)),
              "kind" .= JStr (tlKind tl),
              "durationMs" .= JNum (tlDurationMs tl),
              "impactAtMs" .= JNum (tlImpactAtMs tl)
            ]
      presVal = case cmPresentation m of
        Nothing -> JNull
        Just pr ->
          jObj
            [ "playerHp" .= JNum (fromIntegral (prPlayerHp pr)),
              "enemyHp" .= JNum (fromIntegral (prEnemyHp pr)),
              "playerQi" .= JNum (fromIntegral (prPlayerQi pr)),
              "enemyQi" .= JNum (fromIntegral (prEnemyQi pr))
            ]
      cbVal Nothing = JNull
      cbVal (Just cb) =
        jObj
          [ "combatantSnapshotName" .= JStr (cbName cb),
            "combatantSnapshotHp" .= JNum (fromIntegral (cbHp cb)),
            "combatantSnapshotMaxHp" .= JNum (fromIntegral (cbMaxHp cb)),
            "combatantSnapshotQi" .= JNum (fromIntegral (cbQi cb)),
            "combatantSnapshotMaxQi" .= JNum (fromIntegral (cbMaxQi cb))
          ]
      (playerDashX, playerDashY) =
        if cmReducedMotion m
          then (0.0, 0.0)
          else case mTl of
            Just tl ->
              let sc = sampleBattleScene (Just tl) (cmTimelineElapsedMs m) (raVisual (tlActor tl)) (rtVisual (tlTarget tl)) False
                  pf = scPlayer sc
               in (fsX pf - sideHome SidePlayer, fsY pf)
            Nothing -> (0.0, 0.0)
      stageEventId = maybe "idle" (T.pack . show . tlId) mTl
   in encodeJson $
        jObj
          [ "stageEventId" .= JStr stageEventId,
            "playerDashX" .= JNum playerDashX,
            "playerDashY" .= JNum playerDashY,
            "soundOn" .= JBool (cmSoundOn m),
            "logCount" .= JNum (fromIntegral (length (cmLogs m))),
            "game"
              .= jObj
                [ "battle"
                    .= jObj
                      [ "active" .= JBool (cmInBattle m),
                        "player" .= cbVal (fmap bsPlayer (cmBattleSnap m)),
                        "enemy" .= cbVal (fmap bsEnemy (cmBattleSnap m)),
                        "presentation" .= presVal,
                        "animation"
                          .= jObj
                            [ "activeTimeline" .= tlVal,
                              "queueDepth" .= JNum (fromIntegral (length (cmBattleQueue m) + maybe 0 (const 1) mTl))
                            ]
                      ]
                ],
            "playback"
              .= jObj
                [ "paused" .= JBool (cmLabPaused m),
                  "speed" .= JNum (cmLabSpeed m),
                  "elapsedMs" .= JNum (cmTimelineElapsedMs m),
                  "durationMs" .= JNum (maybe 0 tlDurationMs mTl)
                ]
          ]
