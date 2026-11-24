{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Tingfeng.State
  ( AppPage (..),
    RenderMode (..),
    LogLine (..),
    HitTarget (..),
    CanvasHitbox (..),
    ClientCmd (..),
    PresentationState (..),
    QueuedBattle (..),
    ClientModel (..),
    worldPosFromGrid,
    initClientModel,
    stepClientFrame,
    applyServerMessage,
    setDocumentHidden,
    handlePointerMove,
    handlePointerClick,
    panCameraBy,
    zoomCameraBy,
    resetCameraPan,
    handleUiAction,
    handleLabCommand,
    buildOverlayJson,
    buildLabStateJson,
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

data RenderMode = ModeWebGL2Ink | ModeCanvas2D
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
  | HitToggleRender
  | HitResetCam
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

data ClientCmd
  = CmdSendWs !Text
  | CmdConnectWs !Text !Text !(Maybe CreationChoice)
  | CmdOpenConfigWs
  | CmdSetCursor !Text
  | CmdPlaySfx !Text
  | CmdSaveLocal !Text !Text
  deriving (Show, Eq)

data PresentationState = PresentationState
  { prPlayerHp :: !Int,
    prEnemyHp :: !Int,
    prPlayerQi :: !Int,
    prEnemyQi :: !Int
  }
  deriving (Show, Eq)

data QueuedBattle
  = QCombat !CombatEvt !(Maybe (Int, Int, Int, Int))
  | QSettlement !Text !Text !Bool
  deriving (Show, Eq)

data ClientModel = ClientModel
  { cmPage :: !AppPage,
    cmLocale :: !Locale,
    cmPoseLib :: !PoseLibrary,
    cmCatalog :: !ActionCatalog,
    cmRenderMode :: !RenderMode,
    cmReducedMotion :: !Bool,
    cmDocHidden :: !Bool,
    cmSoundOn :: !Bool,
    cmLookStyle :: !LookStyle,
    cmWidth :: !Double,
    cmHeight :: !Double,
    cmClockMs :: !Double,
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
    cmTransitionBanner :: !(Maybe (Text, Double)),
    cmBattleSnap :: !(Maybe BattleSnap),
    cmCooldownSyncedMs :: !Double,
    cmPresentation :: !(Maybe PresentationState),
    cmPreEventSnap :: !(Maybe (Int, Int, Int, Int)),
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
    cmParticles :: ![InkParticle],
    cmShockPos :: !Pt,
    cmShockAge :: !Double,
    cmShockPower :: !Double,
    -- Panels, Drawers & Logs
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
    cmHovered :: !(Maybe HitTarget),
    cmHitboxes :: ![CanvasHitbox],
    cmUiDirty :: !Bool
  }
  deriving (Show)

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
      cmRenderMode = ModeWebGL2Ink,
      cmReducedMotion = reduced,
      cmDocHidden = False,
      cmSoundOn = False,
      cmLookStyle = LookMaiden,
      cmWidth = max 320 w,
      cmHeight = max 480 h,
      cmClockMs = 0,
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
      cmTransitionBanner = Nothing,
      cmBattleSnap = Nothing,
      cmCooldownSyncedMs = 0,
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
      cmHovered = Nothing,
      cmHitboxes = [],
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

startNextBattleItem :: ClientModel -> (ClientModel, [ClientCmd])
startNextBattleItem m0 =
  case cmBattleQueue m0 of
    [] -> (m0 {cmActiveTimeline = Nothing, cmTimelineElapsedMs = 0, cmAppliedHits = 0, cmUiDirty = True}, [])
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
                    (Nothing, Just (php, ehp, pqi, eqi)) -> PresentationState php ehp pqi eqi
                    (Nothing, Nothing) ->
                      case cmBattleSnap m0 of
                        Just bs -> PresentationState (cbHp (bsPlayer bs)) (cbHp (bsEnemy bs)) (cbQi (bsPlayer bs)) (cbQi (bsEnemy bs))
                        Nothing -> PresentationState (psHp (cmStats m0)) 100 (psQi (cmStats m0)) 100
                  sfxCmds = if cmSoundOn m0 && tlKind tl /= "effect_tick" then [CmdPlaySfx "whoosh"] else []
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
                      pr0 = fromMaybe (PresentationState 100 100 100 100) (cmPresentation m0)
                      pr1 = foldl' applyOne pr0 dueIdx
                      lastIdx = last dueIdx
                      lastHit = hits !! lastIdx
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
                          { cmPresentation = Just pr1,
                            cmAppliedHits = lastIdx + 1,
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
   in if hidden then fst (drainImmediately m1) else m1

applyServerMessage :: ServerMsg -> ClientModel -> (ClientModel, [ClientCmd])
applyServerMessage msg m0 = case msg of
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
    let nextMo = case cmMapOverview m0 of
          Just mo ->
            case find (\r -> mrRoomName r == rName) (moRooms mo) of
              Just r -> Just (mo {moCurrentPos = mrPos r})
              Nothing -> Just mo
          Nothing -> Nothing
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
        cmds =
          if not (cmRequestedInit m1)
            then
              [ CmdSendWs (encodePlayerAction (ActOther "map")),
                CmdSendWs (encodePlayerAction (ActOther "quests")),
                CmdSendWs (encodePlayerAction (ActOther "inventory")),
                CmdSendWs (encodePlayerAction (ActOther "arts"))
              ]
            else [CmdSendWs (encodePlayerAction (ActOther "map"))]
     in (m1 {cmRequestedInit = True}, cmds)
  SmMapOverview mo ->
    let mapChanged = fmap moMapId (cmMapOverview m0) /= Just (moMapId mo)
        m1 = updateCameraTarget (m0 {cmMapOverview = Just mo, cmUiDirty = True})
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
        nextPres =
          if idleQueue
            then Just (PresentationState (cbHp p) (cbHp e) (cbQi p) (cbQi e))
            else case cmPresentation m0 of
              Just pr -> Just (pr {prPlayerQi = cbQi p, prEnemyQi = cbQi e})
              Nothing -> Just (PresentationState (cbHp p) (cbHp e) (cbQi p) (cbQi e))
        pRatio = fromIntegral (maybe (cbHp p) prPlayerHp nextPres) / fromIntegral (max 1 (cbMaxHp p))
        eRatio = fromIntegral (maybe (cbHp e) prEnemyHp nextPres) / fromIntegral (max 1 (cbMaxHp e))
        m1 =
          m0
            { cmInBattle = True,
              cmBattleSnap = Just bs,
              cmCooldownSyncedMs = cmClockMs m0,
              cmPresentation = nextPres,
              cmPreEventSnap = Just (cbHp p, cbHp e, cbQi p, cbQi e),
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
      w = max 320.0 rawW
      h = max 480.0 rawH
      nowMs = cmClockMs m0 + dtSec * 1000.0

      -- Unconditionally stable analytical exponential camera smoothing (immune to large frame hitches)
      camAlpha = if cmReducedMotion m0 then 1.0 else 1.0 - exp (-14.0 * dtSec)
      cx1 = cmCamX m0 + (cmTargetCamX m0 - cmCamX m0) * camAlpha
      cy1 = cmCamY m0 + (cmTargetCamY m0 - cmCamY m0) * camAlpha
      vx1 = 0.0
      vy1 = 0.0

      -- Trailing damage bars
      pCurRatio = case (cmPresentation m0, cmBattleSnap m0) of
        (Just pr, Just bs) -> fromIntegral (prPlayerHp pr) / fromIntegral (max 1 (cbMaxHp (bsPlayer bs)))
        _ -> fromIntegral (psHp (cmStats m0)) / fromIntegral (max 1 (psMaxHp (cmStats m0)))
      eCurRatio = case (cmPresentation m0, cmBattleSnap m0) of
        (Just pr, Just bs) -> fromIntegral (prEnemyHp pr) / fromIntegral (max 1 (cbMaxHp (bsEnemy bs)))
        _ -> 1.0
      stepTrail cur tgt = if cur > tgt then max tgt (cur - dtSec * 0.45) else tgt
      pTrail1 = stepTrail (cmPlayerHpTrail m0) pCurRatio
      eTrail1 = stepTrail (cmEnemyHpTrail m0) eCurRatio

      -- AP smooth interpolation based on agility
      (pAgi, eAgi) = case cmBattleSnap m0 of
        Just bs -> (fromIntegral (cbAgility (bsPlayer bs)), fromIntegral (cbAgility (bsEnemy bs)))
        Nothing -> (fromIntegral (psAgility (cmStats m0)), 18.0)
      apRate agi = (0.55 + agi * 0.022) * dtSec
      pAp1 = if cmInBattle m0 && not (cmLabPaused m0) then min 100.0 (cmPlayerApAnim m0 + apRate pAgi * 18.0) else cmPlayerApAnim m0
      eAp1 = if cmInBattle m0 && not (cmLabPaused m0) then min 100.0 (cmEnemyApAnim m0 + apRate eAgi * 18.0) else cmEnemyApAnim m0

      -- Transition banner decay
      nextBanner = case cmTransitionBanner m0 of
        Nothing -> Nothing
        Just (txt, remMs) ->
          let r' = remMs - dtSec * 1000.0
           in if r' <= 0 then Nothing else Just (txt, r')

      -- Advance active combat timeline
      effDtMs = if cmLabPaused m0 then 0.0 else dtSec * 1000.0 * cmLabSpeed m0
      (mAfterTl, tlCmds) = stepBattleTimeline effDtMs (m0 {cmWidth = w, cmHeight = h, cmClockMs = nowMs})

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

      bannerChanged = isJust (cmTransitionBanner m0) /= isJust nextBanner
   in ( mAfterTl
          { cmCamX = cx1,
            cmCamY = cy1,
            cmCamVx = vx1,
            cmCamVy = vy1,
            cmPlayerHpTrail = pTrail1,
            cmEnemyHpTrail = eTrail1,
            cmPlayerApAnim = pAp1,
            cmEnemyApAnim = eAp1,
            cmTransitionBanner = nextBanner,
            cmParticles = liveParts,
            cmShockAge = min 99.0 (cmShockAge mAfterTl + dtSec),
            cmUiDirty = cmUiDirty mAfterTl || bannerChanged
          },
        tlCmds
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

-- Pointer & Camera Controls

findHit :: Double -> Double -> [CanvasHitbox] -> Maybe CanvasHitbox
findHit x y =
  listToMaybe
    . filter (\hb -> x >= chX hb && x <= chX hb + chW hb && y >= chY hb && y <= chY hb + chH hb)

handlePointerMove :: Double -> Double -> ClientModel -> (ClientModel, [ClientCmd])
handlePointerMove x y m =
  let mHit = findHit x y (cmHitboxes m)
      nextTarget = fmap chTarget mHit
      cursor = maybe "default" chCursor mHit
      cmds = if nextTarget /= cmHovered m then [CmdSetCursor cursor] else []
   in (m {cmHovered = nextTarget}, cmds)

handlePointerClick :: Double -> Double -> ClientModel -> (ClientModel, [ClientCmd])
handlePointerClick x y m =
  case fmap chTarget (findHit x y (cmHitboxes m)) of
    Nothing -> (m, [])
    Just (HitExit dir) ->
      if cmConnected m && not (cmStoryActive m)
        then (m, [CmdSendWs (encodePlayerAction (ActGo dir))])
        else (m, [])
    Just (HitNpc cid) ->
      let nextSel = if cmSelectedNpc m == Just cid then Nothing else Just cid
       in (m {cmSelectedNpc = nextSel, cmUiDirty = True}, [])
    Just HitToggleRender ->
      let next = if cmRenderMode m == ModeWebGL2Ink then ModeCanvas2D else ModeWebGL2Ink
       in (m {cmRenderMode = next, cmUiDirty = True}, [])
    Just HitResetCam ->
      (resetCameraPan m, [])

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

-- UI Actions from Thin Overlay

handleUiAction :: Text -> Text -> Text -> ClientModel -> (ClientModel, [ClientCmd])
handleUiAction kind a1 a2 m0 = case kind of
  "reset_cam" ->
    (resetCameraPan m0, [])
  "request_creation_cfg" ->
    (m0, [CmdOpenConfigWs])
  "set_locale" ->
    (m0 {cmLocale = parseLocale a1, cmUiDirty = True}, [])
  "toggle_locale" ->
    let next = if cmLocale m0 == Zh then En else Zh
     in (m0 {cmLocale = next, cmUiDirty = True}, [])
  "toggle_render" ->
    let next = if cmRenderMode m0 == ModeWebGL2Ink then ModeCanvas2D else ModeWebGL2Ink
     in (m0 {cmRenderMode = next, cmUiDirty = True}, [])
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
     in (m0 {cmDesktopDrawer = next, cmUiDirty = True}, [])
  "char_subtab" ->
    (m0 {cmCharSubTab = a1, cmUiDirty = True}, [])
  "mobile_tab" ->
    let unread = if a1 == "log" then 0 else cmUnreadLogs m0
     in (m0 {cmMobileTab = a1, cmUnreadLogs = unread, cmUiDirty = True}, [])
  "select_npc" ->
    let next = if T.null a1 || cmSelectedNpc m0 == Just a1 then Nothing else Just a1
     in (m0 {cmSelectedNpc = next, cmUiDirty = True}, [])
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

-- Serialize full UI state for thin responsive HTML shell & Playwright inspection

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
   in encodeJson $
        jObj
          [ "game"
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

portraitScoreFile :: Int -> Text
portraitScoreFile app =
  let evenScore = max 0 (min 10 (((app + 1) `div` 2) * 2))
      twoDigit = if evenScore < 10 then "0" <> T.pack (show evenScore) else T.pack (show evenScore)
   in "/portraits/beauty-score-" <> twoDigit <> ".png"

buildOverlayJson :: ClientModel -> Text
buildOverlayJson m =
  let loc = cmLocale m
      st = cmStats m
      nowMs = cmClockMs m
      statsAgeSec = max 0.0 ((nowMs - cmStatsSyncedAtMs m) / 1000.0)
      cdAgeSec = max 0.0 ((nowMs - cmCooldownSyncedMs m) / 1000.0)
      liveInjured = max 0 (psInjuredSeconds st - floor statsAgeSec)

      presHp = case (cmInBattle m, cmPresentation m, cmBattleSnap m) of
        (True, Just pr, _) -> prPlayerHp pr
        (True, Nothing, Just bs) -> cbHp (bsPlayer bs)
        _ -> psHp st
      presMaxHp = case (cmInBattle m, cmBattleSnap m) of
        (True, Just bs) -> cbMaxHp (bsPlayer bs)
        _ -> psMaxHp st
      presQi = case (cmInBattle m, cmPresentation m, cmBattleSnap m) of
        (True, Just pr, _) -> prPlayerQi pr
        (True, Nothing, Just bs) -> cbQi (bsPlayer bs)
        _ -> psQi st
      presMaxQi = case (cmInBattle m, cmBattleSnap m) of
        (True, Just bs) -> cbMaxQi (bsPlayer bs)
        _ -> psMaxQi st

      enemyHp = case (cmPresentation m, cmBattleSnap m) of
        (Just pr, _) -> prEnemyHp pr
        (Nothing, Just bs) -> cbHp (bsEnemy bs)
        _ -> 0
      enemyMaxHp = maybe 1 (cbMaxHp . bsEnemy) (cmBattleSnap m)
      enemyQi = case (cmPresentation m, cmBattleSnap m) of
        (Just pr, _) -> prEnemyQi pr
        (Nothing, Just bs) -> cbQi (bsEnemy bs)
        _ -> 0
      enemyMaxQi = maybe 1 (cbMaxQi . bsEnemy) (cmBattleSnap m)

      busyVal = case psBusy st of
        Nothing -> JNull
        Just bi ->
          let remS = max 0.0 (biSeconds bi - statsAgeSec)
              totSteps = biCompleted bi + biRemaining bi
              actLbl = tr loc ("training.action." <> biAction bi)
              targetName =
                fromMaybe (biTarget bi) $
                  fmap aiName (find (\a -> aiId a == biTarget bi) (cmArts m))
           in jObj
                [ "label" .= JStr (actLbl <> " " <> targetName <> " " <> T.pack (show (biCompleted bi)) <> "/" <> T.pack (show totSteps)),
                  "remainingSec" .= JNum remS,
                  "stepSec" .= JNum (max 0.2 (biStepSeconds bi))
                ]

      creationJson = case cmCreationCfg m of
        Nothing -> JNull
        Just cfg ->
          let cc = cmCreateChoice m
              findOpt nid = find (\o -> coId o == nid)
              bOrig = maybe emptyBonus coBonus (findOpt (ccOrigin cc) (cfgOrigins cfg))
              bC1 = maybe emptyBonus coBonus (findOpt (ccChildhood1 cc) (cfgChildhood1 cfg))
              bC2 = maybe emptyBonus coBonus (findOpt (ccChildhood2 cc) (cfgChildhood2 cfg))
              tot = foldl' addBonus (cfgBaseStats cfg) [bOrig, bC1, bC2]
              pName = if T.null (T.strip (cmUsername m)) then "无名客" else T.strip (cmUsername m)
              encOpt o =
                jObj
                  [ "id" .= JStr (coId o),
                    "label" .= JStr (coLabel o),
                    "story" .= JStr (T.replace "{name}" pName (coStory o))
                  ]
           in jObj
                [ "step" .= JNum (fromIntegral (cmCreateStep m)),
                  "gender" .= JStr (ccGender cc),
                  "origin" .= JStr (ccOrigin cc),
                  "childhood1" .= JStr (ccChildhood1 cc),
                  "childhood2" .= JStr (ccChildhood2 cc),
                  "genders" .= JArr [jObj ["id" .= JStr gid, "label" .= JStr glbl] | (gid, glbl) <- cfgGenders cfg],
                  "origins" .= JArr (map encOpt (cfgOrigins cfg)),
                  "childhood1List" .= JArr (map encOpt (cfgChildhood1 cfg)),
                  "childhood2List" .= JArr (map encOpt (cfgChildhood2 cfg)),
                  "preview"
                    .= jObj
                      [ "strength" .= JNum (fromIntegral (cbStrength tot)),
                        "agility" .= JNum (fromIntegral (cbAgilityValue tot)),
                        "vitality" .= JNum (fromIntegral (cbVitality tot)),
                        "maxQi" .= JNum (fromIntegral (cbMaxQiBonus tot)),
                        "appearance" .= JNum (fromIntegral (max 0 (min 10 (cbAppearance tot)))),
                        "portrait" .= JStr (portraitScoreFile (cbAppearance tot))
                      ]
                ]

      labActions =
        [ jObj ["id" .= JStr aid, "label" .= JStr (adLabel act)]
          | aid <- acOrder (cmCatalog m),
            Just act <- [M.lookup aid (acActions (cmCatalog m))],
            isTravelMotion (adActorMotion act) || adActorMotion act == "focus" || "rig.effect." `T.isPrefixOf` aid
        ]

      pEffects = maybe [] (cbEffects . bsPlayer) (cmBattleSnap m)

      (playerDashX, playerDashY) =
        if cmReducedMotion m
          then (0.0, 0.0)
          else case cmActiveTimeline m of
            Just tl ->
              let sc = sampleBattleScene (Just tl) (cmTimelineElapsedMs m) (raVisual (tlActor tl)) (rtVisual (tlTarget tl)) False
                  pf = scPlayer sc
               in (fsX pf - sideHome SidePlayer, fsY pf)
            Nothing -> (0.0, 0.0)

      stageEventId = maybe "idle" (T.pack . show . tlId) (cmActiveTimeline m)
   in encodeJson $
        jObj
          [ "page" .= JStr (case cmPage m of PageGame -> "game"; PageBattleLab -> "lab"; PagePoseSheet -> "poses"),
            "playerDashX" .= JNum playerDashX,
            "playerDashY" .= JNum playerDashY,
            "locale" .= JStr (localeText loc),
            "connected" .= JBool (cmConnected m),
            "connecting" .= JBool (cmConnecting m),
            "username" .= JStr (cmUsername m),
            "lastError" .= maybe JNull JStr (cmLastError m),
            "loginMode" .= JStr (cmLoginMode m),
            "creation" .= creationJson,
            "renderMode" .= JStr (if cmRenderMode m == ModeWebGL2Ink then "webgl2" else "canvas2d"),
            "soundOn" .= JBool (cmSoundOn m),
            "lookStyle" .= JStr (if cmLookStyle m == LookMaiden then "maiden" else "ponytail"),
            "inBattle" .= JBool (cmInBattle m),
            "storyActive" .= JBool (cmStoryActive m),
            "stageEventId" .= JStr stageEventId,
            "desktopDrawer" .= JStr (cmDesktopDrawer m),
            "charSubTab" .= JStr (cmCharSubTab m),
            "mobileTab" .= JStr (cmMobileTab m),
            "unreadLogs" .= JNum (fromIntegral (cmUnreadLogs m)),
            "selectedNpc" .= maybe JNull JStr (cmSelectedNpc m),
            "mapName"
              .= JStr
                ( case cmMapOverview m of
                    Just mo
                      | T.null (cmRoomName m)
                          || any (\r -> mrPos r == moCurrentPos mo && mrRoomName r == cmRoomName m) (moRooms mo) ->
                          moMapName mo
                    _ -> ""
                ),
            "mapPanned" .= JBool (isCameraPanned m),
            "roomName" .= JStr (cmRoomName m),
            "roomDesc" .= JStr (cmRoomDesc m),
            "portrait" .= JStr (portraitScoreFile (psAppearance st)),
            "genderLabel" .= JStr (tr loc ("gender." <> psGender st)),
            "appearance" .= JNum (fromIntegral (psAppearance st)),
            "appearanceText" .= JStr (psAppearanceText st),
            "hp" .= JNum (fromIntegral presHp),
            "maxHp" .= JNum (fromIntegral presMaxHp),
            "qi" .= JNum (fromIntegral presQi),
            "maxQi" .= JNum (fromIntegral presMaxQi),
            "jing" .= JNum (fromIntegral (psJing st)),
            "maxJing" .= JNum (fromIntegral (psMaxJing st)),
            "enemyName" .= JStr (maybe "对手" (cbName . bsEnemy) (cmBattleSnap m)),
            "enemyHp" .= JNum (fromIntegral enemyHp),
            "enemyMaxHp" .= JNum (fromIntegral enemyMaxHp),
            "enemyQi" .= JNum (fromIntegral enemyQi),
            "enemyMaxQi" .= JNum (fromIntegral enemyMaxQi),
            "money" .= JNum (fromIntegral (cmMoney m)),
            "potential" .= JNum (fromIntegral (psPotential st)),
            "combatExp" .= JNum (fromIntegral (psCombatExp st)),
            "strength" .= JNum (fromIntegral (psStrength st)),
            "agility" .= JNum (fromIntegral (psAgility st)),
            "vitality" .= JNum (fromIntegral (psVitality st)),
            "injuredSec" .= JNum (fromIntegral liveInjured),
            "combatInsight" .= JNum (fromIntegral (psCombatInsight st)),
            "busy" .= busyVal,
            "npcs"
              .= JArr
                [ jObj
                    [ "id" .= JStr (rcId c),
                      "name" .= JStr (rcName c),
                      "desc" .= JStr (rcDesc c),
                      "actions" .= JArr (map JStr (rcActions c)),
                      "teaches"
                        .= JArr
                          [ jObj ["id" .= JStr (taId t), "name" .= JStr (taName t), "maxLevel" .= JNum (fromIntegral (taMaxLevel t))]
                            | t <- rcTeaches c
                          ],
                      "shop"
                        .= JArr
                          [ jObj ["id" .= JStr (siId s), "name" .= JStr (siName s), "price" .= JNum (fromIntegral (siPrice s))]
                            | s <- rcShop c
                          ]
                    ]
                  | c <- cmRoomChars m
                ],
            "skills"
              .= JArr
                [ let cdRem = max 0.0 (fromMaybe 0.0 (M.lookup (asId sk) cds) - cdAgeSec)
                      apCur = maybe 0 (cbAp . bsPlayer) (cmBattleSnap m)
                      hasReqs = all (\reqId -> any (\ef -> efId ef == reqId && efRemaining ef - cdAgeSec > 0.05) pEffects) (asReqStatus sk)
                      ready = cdRem <= 0.05 && presQi >= asCost sk && apCur >= asApReq sk && hasReqs
                      queued = bsPendingSkillId bs == Just (asId sk)
                   in jObj
                        [ "id" .= JStr (asId sk),
                          "name" .= JStr (asName sk),
                          "desc" .= JStr (asDesc sk),
                          "cost" .= JNum (fromIntegral (asCost sk)),
                          "ap" .= JNum (fromIntegral (asApReq sk)),
                          "cdRem" .= JNum cdRem,
                          "cdTotal" .= JNum (max 1.0 (asCooldown sk)),
                          "ready" .= JBool ready,
                          "queued" .= JBool queued
                        ]
                  | Just bs <- [cmBattleSnap m],
                    let cds = bsCooldowns bs,
                    sk <- bsActiveSkills bs
                ],
            "arts"
              .= JArr
                [ let blkTxt = case aiBlocker a of
                        Just "combat_exp" -> trParams loc "art.blocker.combat_exp" [("required", T.pack (show (aiNextCombatExp a)))]
                        Just "foundation" -> tr loc "art.blocker.foundation"
                        Just "max_level" -> tr loc "art.blocker.max_level"
                        _ -> ""
                      canRes = not (aiIsFoundation a) && aiLevel a >= aiResearchFrom a && aiLevel a < aiMaxLevel a
                   in jObj
                        [ "id" .= JStr (aiId a),
                          "name" .= JStr (aiName a),
                          "typeRaw" .= JStr (aiType a),
                          "typeLabel" .= JStr (formatArtType loc (aiType a)),
                          "rank" .= JStr (artRankTitle loc (aiLevel a)),
                          "levelText" .= JStr (trParams loc "art.level" [("level", T.pack (show (aiLevel a))), ("max", T.pack (show (aiMaxLevel a)))]),
                          "progress" .= JNum (fromIntegral (aiProgress a)),
                          "nextProgress" .= JNum (fromIntegral (aiNextProgress a)),
                          "foundation" .= JBool (aiIsFoundation a),
                          "enabled" .= JBool (aiEnabled a),
                          "maxed" .= JBool (aiBlocker a == Just "max_level"),
                          "canResearch" .= JBool canRes,
                          "blocker" .= JStr blkTxt,
                          "moves" .= JStr (T.intercalate " / " (aiUnlockedMoves a <> aiUnlockedSkills a))
                        ]
                  | a <- cmArts m
                ],
            "inventory"
              .= JArr
                [ jObj
                    [ "id" .= JStr (iiId it),
                      "name" .= JStr (iiName it),
                      "amount" .= JNum (fromIntegral (iiAmount it)),
                      "usable" .= JBool (iiUsable it),
                      "studyable" .= JBool (iiStudyable it),
                      "equipped" .= JBool (iiEquipped it),
                      "hasSlot" .= JBool (isJust (iiEquipSlot it))
                    ]
                  | it <- cmInventory m
                ],
            "quests"
              .= JArr
                [ jObj
                    [ "name" .= JStr (qiName q),
                      "objective" .= maybe (JStr "") JStr (qiObjective q),
                      "done" .= JBool (qiCompleted q),
                      "rewards" .= JStr (T.intercalate ", " [rwName r <> " ×" <> T.pack (show (rwAmount r)) | r <- qiRewards q])
                    ]
                  | q <- cmQuests m
                ],
            "logs"
              .= JArr
                [ jObj
                    [ "id" .= JNum (fromIntegral (llId l)),
                      "kind" .= JStr (llKind l),
                      "text" .= JStr (llText l)
                    ]
                  | l <- cmLogs m
                ],
            "labActions" .= JArr labActions,
            "labPaused" .= JBool (cmLabPaused m),
            "labSpeed" .= JNum (cmLabSpeed m),
            "labElapsedMs" .= JNum (cmTimelineElapsedMs m),
            "labDurationMs" .= JNum (maybe 0 tlDurationMs (cmActiveTimeline m))
          ]
