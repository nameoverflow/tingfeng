{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Tingfeng.Protocol
  ( Direction (..),
    directionText,
    parseDirection,
    directionLabel,
    directionVec,
    directionGridDelta,
    PlayerAction (..),
    CreationBonus (..),
    emptyBonus,
    addBonus,
    CreationOption (..),
    CreationConfig (..),
    CreationChoice (..),
    TeachableArt (..),
    ShopItem (..),
    RoomChar (..),
    RoomExit (..),
    MapRoom (..),
    MapEdge (..),
    MapOverview (..),
    EffectInfo (..),
    ActiveSkillInfo (..),
    CombatantInfo (..),
    BattleSnap (..),
    CombatResult (..),
    combatResultText,
    parseCombatResult,
    CombatHit (..),
    CombatEvt (..),
    SkillFailReason (..),
    BusyInfo (..),
    PlayerStatsInfo (..),
    ArtInfo (..),
    InvItem (..),
    RewardInfo (..),
    QuestItem (..),
    ServerMsg (..),
    encodeLogin,
    encodeRequestCreationConfig,
    encodePlayerAction,
    decodeServerMsg,
  )
where

import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Tingfeng.I18n (Locale (..))
import Tingfeng.Json

data Direction
  = North
  | South
  | East
  | West
  | NorthEast
  | NorthWest
  | SouthEast
  | SouthWest
  deriving (Show, Eq, Ord)

directionText :: Direction -> Text
directionText North = "North"
directionText South = "South"
directionText East = "East"
directionText West = "West"
directionText NorthEast = "NorthEast"
directionText NorthWest = "NorthWest"
directionText SouthEast = "SouthEast"
directionText SouthWest = "SouthWest"

parseDirection :: Text -> Maybe Direction
parseDirection "North" = Just North
parseDirection "South" = Just South
parseDirection "East" = Just East
parseDirection "West" = Just West
parseDirection "NorthEast" = Just NorthEast
parseDirection "NorthWest" = Just NorthWest
parseDirection "SouthEast" = Just SouthEast
parseDirection "SouthWest" = Just SouthWest
parseDirection _ = Nothing

directionLabel :: Locale -> Direction -> Text
directionLabel Zh North = "北"
directionLabel Zh South = "南"
directionLabel Zh East = "东"
directionLabel Zh West = "西"
directionLabel Zh NorthEast = "东北"
directionLabel Zh NorthWest = "西北"
directionLabel Zh SouthEast = "东南"
directionLabel Zh SouthWest = "西南"
directionLabel En North = "N"
directionLabel En South = "S"
directionLabel En East = "E"
directionLabel En West = "W"
directionLabel En NorthEast = "NE"
directionLabel En NorthWest = "NW"
directionLabel En SouthEast = "SE"
directionLabel En SouthWest = "SW"

directionVec :: Direction -> (Double, Double)
directionVec North = (0, -1)
directionVec South = (0, 1)
directionVec East = (1, 0)
directionVec West = (-1, 0)
directionVec NorthEast = (0.76, -0.76)
directionVec NorthWest = (-0.76, -0.76)
directionVec SouthEast = (0.76, 0.76)
directionVec SouthWest = (-0.76, 0.76)

directionGridDelta :: Direction -> (Int, Int)
directionGridDelta North = (0, 1)
directionGridDelta South = (0, -1)
directionGridDelta East = (1, 0)
directionGridDelta West = (-1, 0)
directionGridDelta NorthEast = (1, 1)
directionGridDelta NorthWest = (-1, 1)
directionGridDelta SouthEast = (1, -1)
directionGridDelta SouthWest = (-1, -1)

data PlayerAction
  = ActGo !Direction
  | ActTalk !Text
  | ActAttack !Text
  | ActPerform !Text
  | ActTrain !Text
  | ActPractice !Text !Int
  | ActLearn !Text !Text !Int
  | ActStudy !Text !Int
  | ActResearch !Text !Int
  | ActMeditate !Int !Int
  | ActEnable !Text !Text
  | ActPrepare !Text !Text
  | ActEquip !Text
  | ActUnequip !Text
  | ActBuy !(Maybe Text) !Text
  | ActUse !Text
  | ActSay !Text
  | ActOther !Text
  deriving (Show, Eq)

data CreationBonus = CreationBonus
  { cbStrength :: !Int,
    cbAgilityValue :: !Int,
    cbVitality :: !Int,
    cbMaxQiBonus :: !Int,
    cbAppearance :: !Int
  }
  deriving (Show, Eq)

emptyBonus :: CreationBonus
emptyBonus = CreationBonus 0 0 0 0 0

addBonus :: CreationBonus -> CreationBonus -> CreationBonus
addBonus a b =
  CreationBonus
    (cbStrength a + cbStrength b)
    (cbAgilityValue a + cbAgilityValue b)
    (cbVitality a + cbVitality b)
    (cbMaxQiBonus a + cbMaxQiBonus b)
    (cbAppearance a + cbAppearance b)

data CreationOption = CreationOption
  { coId :: !Text,
    coLabel :: !Text,
    coStory :: !Text,
    coBonus :: !CreationBonus
  }
  deriving (Show, Eq)

data CreationConfig = CreationConfig
  { cfgBaseStats :: !CreationBonus,
    cfgGenders :: ![(Text, Text)],
    cfgOrigins :: ![CreationOption],
    cfgChildhood1 :: ![CreationOption],
    cfgChildhood2 :: ![CreationOption]
  }
  deriving (Show, Eq)

data CreationChoice = CreationChoice
  { ccGender :: !Text,
    ccOrigin :: !Text,
    ccChildhood1 :: !Text,
    ccChildhood2 :: !Text
  }
  deriving (Show, Eq)

encodeLogin :: Text -> Text -> Maybe CreationChoice -> Text
encodeLogin user pass mChoice =
  encodeJson $
    jObj
      [ "tag" .= JStr "Login",
        "username" .= JStr user,
        "password" .= JStr pass,
        "creation" .= case mChoice of
          Nothing -> JNull
          Just cc ->
            jObj
              [ "gender" .= JStr (ccGender cc),
                "origin" .= JStr (ccOrigin cc),
                "childhood1" .= JStr (ccChildhood1 cc),
                "childhood2" .= JStr (ccChildhood2 cc)
              ]
      ]

encodeRequestCreationConfig :: Text
encodeRequestCreationConfig =
  encodeJson (jObj ["tag" .= JStr "RequestCharacterCreationConfig"])

encodePlayerAction :: PlayerAction -> Text
encodePlayerAction act =
  encodeJson $
    jObj
      [ "tag" .= JStr "NetPlayerAction",
        "contents" .= body act
      ]
  where
    body (ActGo dir) = jObj ["go" .= JStr (directionText dir)]
    body (ActTalk cid) = jObj ["talk" .= JStr cid]
    body (ActAttack cid) = jObj ["attack" .= JStr cid]
    body (ActPerform sid) = jObj ["perform" .= JStr sid]
    body (ActTrain aid) = jObj ["train" .= JStr aid]
    body (ActPractice aid n) =
      jObj ["practice" .= jObj ["art" .= JStr aid, "times" .= JNum (fromIntegral n)]]
    body (ActLearn tid aid n) =
      jObj ["learn" .= jObj ["teacher" .= JStr tid, "art" .= JStr aid, "times" .= JNum (fromIntegral n)]]
    body (ActStudy iid n) =
      jObj ["study" .= jObj ["item" .= JStr iid, "times" .= JNum (fromIntegral n)]]
    body (ActResearch aid n) =
      jObj ["research" .= jObj ["art" .= JStr aid, "times" .= JNum (fromIntegral n)]]
    body (ActMeditate amt n) =
      jObj ["meditate" .= jObj ["amount" .= JNum (fromIntegral amt), "times" .= JNum (fromIntegral n)]]
    body (ActEnable ty aid) =
      jObj ["enable" .= jObj ["type" .= JStr ty, "art" .= JStr aid]]
    body (ActPrepare ty aid) =
      jObj ["prepare" .= jObj ["type" .= JStr ty, "art" .= JStr aid]]
    body (ActEquip iid) = jObj ["equip" .= JStr iid]
    body (ActUnequip slot) = jObj ["unequip" .= JStr slot]
    body (ActBuy mMerch iid) =
      jObj
        [ "buy"
            .= jObj
              ( ["item" .= JStr iid]
                  <> maybe [] (\m -> ["merchant" .= JStr m]) mMerch
              )
        ]
    body (ActUse iid) = jObj ["use" .= JStr iid]
    body (ActSay msg) = jObj ["say" .= JStr msg]
    body (ActOther cmd) = jObj ["other" .= JStr cmd]

data TeachableArt = TeachableArt
  { taId :: !Text,
    taName :: !Text,
    taMaxLevel :: !Int
  }
  deriving (Show, Eq)

data ShopItem = ShopItem
  { siId :: !Text,
    siName :: !Text,
    siPrice :: !Int
  }
  deriving (Show, Eq)

data RoomChar = RoomChar
  { rcId :: !Text,
    rcName :: !Text,
    rcDesc :: !Text,
    rcActions :: ![Text],
    rcTeaches :: ![TeachableArt],
    rcShop :: ![ShopItem]
  }
  deriving (Show, Eq)

data RoomExit = RoomExit
  { reDirection :: !Direction,
    reMapId :: !Text,
    reRoomId :: !Text,
    reRoomName :: !Text,
    rePos :: !(Maybe (Int, Int))
  }
  deriving (Show, Eq)

data MapRoom = MapRoom
  { mrRoomId :: !Text,
    mrRoomName :: !Text,
    mrRoomKind :: !Text,
    mrPos :: !(Int, Int)
  }
  deriving (Show, Eq)

data MapEdge = MapEdge
  { meDirection :: !Direction,
    meFrom :: !(Int, Int),
    meTo :: !(Int, Int),
    meToRoomId :: !Text,
    meToRoomName :: !Text,
    meToMapId :: !Text,
    meToMapName :: !Text
  }
  deriving (Show, Eq)

data MapOverview = MapOverview
  { moMapId :: !Text,
    moMapName :: !Text,
    moCurrentPos :: !(Int, Int),
    moRooms :: ![MapRoom],
    moEdges :: ![MapEdge]
  }
  deriving (Show, Eq)

data EffectInfo = EffectInfo
  { efId :: !Text,
    efName :: !Text,
    efType :: !Text,
    efRemaining :: !Double,
    efValue :: !Int
  }
  deriving (Show, Eq)

data ActiveSkillInfo = ActiveSkillInfo
  { asId :: !Text,
    asName :: !Text,
    asDesc :: !Text,
    asCost :: !Int,
    asApReq :: !Int,
    asUnlockLevel :: !Int,
    asCooldown :: !Double,
    asReqStatus :: ![Text],
    asReqStatusNames :: ![Text],
    asDamage :: !(Maybe Int),
    asHeal :: !(Maybe Int)
  }
  deriving (Show, Eq)

data CombatantInfo = CombatantInfo
  { cbId :: !Text,
    cbName :: !Text,
    cbGender :: !Text,
    cbStyle :: !Text,
    cbHp :: !Int,
    cbMaxHp :: !Int,
    cbQi :: !Int,
    cbMaxQi :: !Int,
    cbAp :: !Int,
    cbApProgress :: !Double,
    cbAgility :: !Int,
    cbEffects :: ![EffectInfo]
  }
  deriving (Show, Eq)

data BattleSnap = BattleSnap
  { bsPlayer :: !CombatantInfo,
    bsEnemy :: !CombatantInfo,
    bsCooldowns :: !(M.Map Text Double),
    bsActiveSkills :: ![ActiveSkillInfo],
    bsActionLock :: !Double,
    bsPendingSkillId :: !(Maybe Text)
  }
  deriving (Show, Eq)

data CombatResult = ResHit | ResDodge | ResParry | ResEffect
  deriving (Show, Eq, Ord)

combatResultText :: CombatResult -> Text
combatResultText ResHit = "hit"
combatResultText ResDodge = "dodge"
combatResultText ResParry = "parry"
combatResultText ResEffect = "effect"

parseCombatResult :: Text -> CombatResult
parseCombatResult "dodge" = ResDodge
parseCombatResult "parry" = ResParry
parseCombatResult "effect" = ResEffect
parseCombatResult _ = ResHit

data CombatHit = CombatHit
  { chResult :: !CombatResult,
    chDamage :: !(Maybe Int),
    chHeal :: !(Maybe Int)
  }
  deriving (Show, Eq)

data CombatEvt = CombatEvt
  { ceKind :: !Text,
    ceActorName :: !Text,
    ceTargetName :: !Text,
    ceMsgKind :: !Text,
    ceText :: !Text,
    ceEffectKind :: !Text,
    ceEffectAmount :: !Int,
    ceDamage :: !(Maybe Int),
    ceHeal :: !(Maybe Int),
    ceResult :: !CombatResult,
    ceHits :: ![CombatHit],
    ceActionId :: !Text,
    ceTags :: ![Text],
    ceLabel :: !(Maybe Text),
    ceDurationMs :: !(Maybe Double),
    ceStagingOverride :: !(Maybe JVal)
  }
  deriving (Show, Eq)

data SkillFailReason
  = FailNeedAp !Int !Int
  | FailNeedQi !Int !Int
  | FailCooldown !Int
  | FailMissingStatus ![Text]
  | FailUnavailable !Text
  deriving (Show, Eq)

data BusyInfo = BusyInfo
  { biAction :: !Text,
    biTarget :: !Text,
    biCompleted :: !Int,
    biRemaining :: !Int,
    biSeconds :: !Double,
    biStepSeconds :: !Double
  }
  deriving (Show, Eq)

data PlayerStatsInfo = PlayerStatsInfo
  { psHp :: !Int,
    psMaxHp :: !Int,
    psQi :: !Int,
    psMaxQi :: !Int,
    psJing :: !Int,
    psMaxJing :: !Int,
    psAp :: !Int,
    psStatus :: !Text,
    psGender :: !Text,
    psAppearance :: !Int,
    psAppearanceText :: !Text,
    psPortraitKey :: !Text,
    psStrength :: !Int,
    psAgility :: !Int,
    psVitality :: !Int,
    psPotential :: !Int,
    psCombatExp :: !Int,
    psInjuredSeconds :: !Int,
    psCombatInsight :: !Int,
    psBusy :: !(Maybe BusyInfo)
  }
  deriving (Show, Eq)

data ArtInfo = ArtInfo
  { aiId :: !Text,
    aiName :: !Text,
    aiType :: !Text,
    aiTier :: !Text,
    aiLevel :: !Int,
    aiProgress :: !Int,
    aiNextProgress :: !Int,
    aiMaxLevel :: !Int,
    aiIsFoundation :: !Bool,
    aiEnabled :: !Bool,
    aiResearchFrom :: !Int,
    aiNextCombatExp :: !Int,
    aiBlocker :: !(Maybe Text),
    aiUnlockedMoves :: ![Text],
    aiUnlockedSkills :: ![Text]
  }
  deriving (Show, Eq)

data InvItem = InvItem
  { iiId :: !Text,
    iiName :: !Text,
    iiAmount :: !Int,
    iiUsable :: !Bool,
    iiStudyable :: !Bool,
    iiEquipped :: !Bool,
    iiEquipSlot :: !(Maybe Text)
  }
  deriving (Show, Eq)

data RewardInfo = RewardInfo
  { rwKind :: !Text,
    rwName :: !Text,
    rwAmount :: !Int
  }
  deriving (Show, Eq)

data QuestItem = QuestItem
  { qiId :: !Text,
    qiName :: !Text,
    qiStage :: !Text,
    qiObjective :: !(Maybe Text),
    qiCompleted :: !Bool,
    qiRewards :: ![RewardInfo]
  }
  deriving (Show, Eq)

data ServerMsg
  = SmMove !Text
  | SmView !Text !Text ![RoomChar] ![RoomExit]
  | SmMapOverview !MapOverview
  | SmAttack !Text !Text
  | SmCombatEvent !CombatEvt
  | SmCombatSettlement !Text !Text !Bool
  | SmBattleState !BattleSnap
  | SmActiveSkillFailure !SkillFailReason
  | SmDialogue !Text !Text
  | SmStory !Text !Text
  | SmStorySequence !Bool
  | SmStoryDelay !Int
  | SmStoryTransition !Text !Int
  | SmSay !Text !Text
  | SmUseItem !Text !Text
  | SmPlayerStats !PlayerStatsInfo
  | SmInventory !Int ![InvItem]
  | SmArts ![ArtInfo]
  | SmQuests ![QuestItem]
  | SmReward ![RewardInfo]
  | SmCreationConfig !CreationConfig
  | SmSystem !Text !(M.Map Text Text)
  | SmError !Text !(M.Map Text Text)
  | SmIgnored !Text
  deriving (Show, Eq)

decodePos :: JVal -> Maybe (Int, Int)
decodePos (JArr [a, b]) = (,) <$> jInt a <*> jInt b
decodePos (JObj m) = (,) <$> jField jInt "x" m <*> jField jInt "y" m
decodePos _ = Nothing

decodeServerMsg :: Text -> Either String ServerMsg
decodeServerMsg raw = do
  val <- parseJson raw
  mp <- case val of
    JObj m -> Right m
    _ -> Left "Server message is not an object"
  tag <- maybe (Left "Missing tag") Right (jField jText "tag" mp)
  let c = M.findWithDefault JNull "contents" mp
  Right (decodeByTag tag c)
  where
    decodeByTag "MoveMsg" (JStr dst) = SmMove dst
    decodeByTag "ViewMsg" (JArr [JStr rName, JStr rDesc, JArr chars, JArr exits]) =
      SmView rName rDesc (mapMaybe decChar chars) (mapMaybe decExit exits)
    decodeByTag "MapOverviewMsg" (JObj m) =
      maybe (SmIgnored "MapOverviewMsg") SmMapOverview (decMapOverview m)
    decodeByTag "AttackMsg" (JArr [JStr atk, JStr def]) = SmAttack atk def
    decodeByTag "CombatEventMsg" (JObj m) = SmCombatEvent (decCombatEvt m)
    decodeByTag "CombatSettlementMsg" (JArr [JStr atk, JStr def, JBool win]) =
      SmCombatSettlement atk def win
    decodeByTag "BattleStateMsg" (JObj m) =
      maybe (SmIgnored "BattleStateMsg") SmBattleState (decBattleSnap m)
    decodeByTag "ActiveSkillFailureMsg" (JObj m) =
      SmActiveSkillFailure (decSkillFail m)
    decodeByTag "DialogueMsg" (JArr [JStr who, JStr txt]) = SmDialogue who txt
    decodeByTag "StoryMsg" (JArr [JStr speaker, JStr txt]) = SmStory speaker txt
    decodeByTag "StorySequenceMsg" (JBool active) = SmStorySequence active
    decodeByTag "StoryDelayMsg" n = SmStoryDelay (fromMaybe 0 (jInt n))
    decodeByTag "StoryTransitionMsg" (JArr [JStr txt, n]) =
      SmStoryTransition txt (fromMaybe 1200 (jInt n))
    decodeByTag "SayMsg" (JArr [JStr who, JStr txt]) = SmSay who txt
    decodeByTag "UseItemMsg" (JArr [JStr who, JStr txt]) = SmUseItem who txt
    decodeByTag "PlayerStatsMsg" (JObj m) = SmPlayerStats (decStats m)
    decodeByTag "InventoryMsg" (JArr [moneyVal, JArr items]) =
      SmInventory (fromMaybe 0 (jInt moneyVal)) (mapMaybe decInv items)
    decodeByTag "ArtsMsg" (JArr arts) = SmArts (mapMaybe decArt arts)
    decodeByTag "QuestLogMsg" (JArr qs) = SmQuests (mapMaybe decQuest qs)
    decodeByTag "RewardMsg" (JArr rs) = SmReward (mapMaybe decReward rs)
    decodeByTag "CharacterCreationConfigMsg" (JObj m) =
      SmCreationConfig (decCreationConfig m)
    decodeByTag "SystemMsg" (JObj m) =
      SmSystem
        (jFieldDef "" jText "systemMessageKey" m)
        (decStrMap (M.findWithDefault JNull "systemMessageParams" m))
    decodeByTag "ErrorMsg" (JObj m) =
      SmError
        (jFieldDef "other" jText "errorSummaryCode" m)
        (decStrMap (M.findWithDefault JNull "errorSummaryParams" m))
    decodeByTag other _ = SmIgnored other

    decStrMap (JObj m) = M.mapMaybe jText m
    decStrMap _ = M.empty

    decChar (JObj m) =
      Just $
        RoomChar
          { rcId = jFieldDef "" jText "id" m,
            rcName = jFieldDef "无名氏" jText "name" m,
            rcDesc = jFieldDef "" jText "desc" m,
            rcActions = fromMaybe [] (jField (jList jText) "actions" m),
            rcTeaches = maybe [] (mapMaybe decTeach) (jField (jList Just) "teaches" m),
            rcShop = maybe [] (mapMaybe decShop) (jField (jList Just) "shop" m)
          }
    decChar _ = Nothing

    decTeach (JObj m) =
      Just $
        TeachableArt
          (jFieldDef "" jText "artId" m)
          (jFieldDef "" jText "name" m)
          (jFieldDef 1 jInt "maxLevel" m)
    decTeach _ = Nothing

    decShop (JObj m) =
      Just $
        ShopItem
          (jFieldDef "" jText "itemId" m)
          (jFieldDef "" jText "name" m)
          (jFieldDef 0 jInt "price" m)
    decShop _ = Nothing

    decExit (JObj m) = do
      dirTxt <- jField jText "direction" m
      dir <- parseDirection dirTxt
      Just $
        RoomExit
          { reDirection = dir,
            reMapId = jFieldDef "" jText "mapId" m,
            reRoomId = jFieldDef "" jText "roomId" m,
            reRoomName = jFieldDef (directionLabel Zh dir) jText "roomName" m,
            rePos = M.lookup "position" m >>= decodePos
          }
    decExit _ = Nothing

    decMapOverview m = do
      cPos <- M.lookup "currentPosition" m >>= decodePos
      let rooms = maybe [] (mapMaybe decMapRoom) (jField (jList Just) "rooms" m)
          edges = maybe [] (mapMaybe decMapEdge) (jField (jList Just) "edges" m)
      Just $
        MapOverview
          { moMapId = jFieldDef "" jText "mapId" m,
            moMapName = jFieldDef "江湖舆图" jText "mapName" m,
            moCurrentPos = cPos,
            moRooms = rooms,
            moEdges = edges
          }

    decMapRoom (JObj m) = do
      pos <- M.lookup "position" m >>= decodePos
      Just $
        MapRoom
          { mrRoomId = jFieldDef "" jText "roomId" m,
            mrRoomName = jFieldDef "" jText "roomName" m,
            mrRoomKind = jFieldDef "normal" jText "roomKind" m,
            mrPos = pos
          }
    decMapRoom _ = Nothing

    decMapEdge (JObj m) = do
      dir <- jField jText "direction" m >>= parseDirection
      fPos <- M.lookup "from" m >>= decodePos
      tPos <- M.lookup "to" m >>= decodePos
      Just $
        MapEdge
          { meDirection = dir,
            meFrom = fPos,
            meTo = tPos,
            meToRoomId = jFieldDef "" jText "toRoomId" m,
            meToRoomName = jFieldDef "" jText "toRoomName" m,
            meToMapId = jFieldDef "" jText "toMapId" m,
            meToMapName = jFieldDef "" jText "toMapName" m
          }
    decMapEdge _ = Nothing

    decEffect (JObj m) =
      Just $
        EffectInfo
          (jFieldDef "" jText "effectSummaryId" m)
          (jFieldDef "" jText "effectSummaryName" m)
          (jFieldDef "buff" jText "effectSummaryType" m)
          (jFieldDef 0 jDouble "effectSummaryRemaining" m)
          (jFieldDef 0 jInt "effectSummaryValue" m)
    decEffect _ = Nothing

    decSkill (JObj m) =
      Just $
        ActiveSkillInfo
          { asId = jFieldDef "" jText "activeSkillSummaryId" m,
            asName = jFieldDef "" jText "activeSkillSummaryName" m,
            asDesc = jFieldDef "" jText "activeSkillSummaryDesc" m,
            asCost = jFieldDef 0 jInt "activeSkillSummaryCost" m,
            asApReq = jFieldDef 1 jInt "activeSkillSummaryApReq" m,
            asUnlockLevel = jFieldDef 1 jInt "activeSkillSummaryUnlockLevel" m,
            asCooldown = jFieldDef 0 jDouble "activeSkillSummaryCooldown" m,
            asReqStatus = fromMaybe [] (jField (jList jText) "activeSkillSummaryReqStatus" m),
            asReqStatusNames = fromMaybe [] (jField (jList jText) "activeSkillSummaryReqStatusNames" m),
            asDamage = jFieldMaybe jInt "activeSkillSummaryDamage" m,
            asHeal = jFieldMaybe jInt "activeSkillSummaryHeal" m
          }
    decSkill _ = Nothing

    decCombatant (JObj m) =
      let apInt = jFieldDef 0 jInt "combatantSnapshotAp" m
       in Just $
            CombatantInfo
              { cbId = jFieldDef "" jText "combatantSnapshotId" m,
                cbName = jFieldDef "侠客" jText "combatantSnapshotName" m,
                cbGender = jFieldDef "male" jText "combatantSnapshotGender" m,
                cbStyle = jFieldDef "fist" jText "combatantSnapshotCombatStyle" m,
                cbHp = jFieldDef 100 jInt "combatantSnapshotHp" m,
                cbMaxHp = max 1 (jFieldDef 100 jInt "combatantSnapshotMaxHp" m),
                cbQi = jFieldDef 100 jInt "combatantSnapshotQi" m,
                cbMaxQi = max 1 (jFieldDef 100 jInt "combatantSnapshotMaxQi" m),
                cbAp = apInt,
                cbApProgress = jFieldDef (fromIntegral apInt) jDouble "combatantSnapshotApProgress" m,
                cbAgility = jFieldDef 18 jInt "combatantSnapshotAgility" m,
                cbEffects = maybe [] (mapMaybe decEffect) (jField (jList Just) "combatantSnapshotEffects" m)
              }
    decCombatant _ = Nothing

    decBattleSnap m = do
      pl <- M.lookup "battleSnapshotPlayer" m >>= decCombatant
      en <- M.lookup "battleSnapshotEnemy" m >>= decCombatant
      let cds = case M.lookup "battleSnapshotActiveSkillCooldowns" m of
            Just (JArr xs) ->
              M.fromList
                [ ( jFieldDef "" jText "activeSkillCooldownSummaryActiveSkillId" cm,
                    jFieldDef 0 jDouble "activeSkillCooldownSummaryRemaining" cm
                  )
                  | JObj cm <- xs
                ]
            _ -> M.empty
          skills = maybe [] (mapMaybe decSkill) (jField (jList Just) "battleSnapshotActiveSkills" m)
      Just $
        BattleSnap
          { bsPlayer = pl,
            bsEnemy = en,
            bsCooldowns = cds,
            bsActiveSkills = skills,
            bsActionLock = jFieldDef 0 jDouble "battleSnapshotActionLockRemaining" m,
            bsPendingSkillId = jFieldMaybe jText "battleSnapshotPendingActiveSkillId" m
          }

    decSkillFail m =
      case jFieldDef "unavailable" jText "reason" m of
        "need_ap" -> FailNeedAp (jFieldDef 0 jInt "required" m) (jFieldDef 0 jInt "current" m)
        "need_qi" -> FailNeedQi (jFieldDef 0 jInt "required" m) (jFieldDef 0 jInt "current" m)
        "cooldown" -> FailCooldown (jFieldDef 1 jInt "remaining" m)
        "missing_status" -> FailMissingStatus (fromMaybe [] (jField (jList jText) "statuses" m))
        _ -> FailUnavailable (jFieldDef "" jText "activeSkillId" m)

    decHit (JObj m) =
      Just $
        CombatHit
          (parseCombatResult (jFieldDef "hit" jText "result" m))
          (jFieldMaybe jInt "damage" m)
          (jFieldMaybe jInt "heal" m)
    decHit _ = Nothing

    decCombatEvt m =
      let (mKind, msgText, effKind, effAmt) = case M.lookup "message" m of
            Just (JObj mm) -> case jFieldDef "script" jText "kind" mm of
              "effect_tick" ->
                ( "effect_tick",
                  jFieldDef "内息" jText "effectName" mm,
                  jFieldDef "dot" jText "effectKind" mm,
                  jFieldDef 0 jInt "amount" mm
                )
              _ -> ("script", jFieldDef "" jText "text" mm, "", 0)
            _ -> ("script", "", "", 0)
          (actId, tags, mLbl, mDur, mStg) = case M.lookup "visual" m of
            Just (JObj vm) ->
              let (lbl, stg) = case M.lookup "params" vm of
                    Just (JObj pm) ->
                      ( jFieldMaybe jText "label" pm,
                        M.lookup "staging" pm
                      )
                    _ -> (Nothing, Nothing)
               in ( jFieldDef "" jText "actionId" vm,
                    fromMaybe [] (jField (jList jText) "tags" vm),
                    lbl,
                    jFieldMaybe jDouble "durationMs" vm,
                    stg
                  )
            _ -> ("", [], Nothing, Nothing, Nothing)
       in CombatEvt
            { ceKind = jFieldDef "normal" jText "kind" m,
              ceActorName = jFieldDef "" jText "actorName" m,
              ceTargetName = jFieldDef "" jText "targetName" m,
              ceMsgKind = mKind,
              ceText = msgText,
              ceEffectKind = effKind,
              ceEffectAmount = effAmt,
              ceDamage = jFieldMaybe jInt "damage" m,
              ceHeal = jFieldMaybe jInt "heal" m,
              ceResult = parseCombatResult (jFieldDef "hit" jText "result" m),
              ceHits = maybe [] (mapMaybe decHit) (jField (jList Just) "hits" m),
              ceActionId = actId,
              ceTags = tags,
              ceLabel = mLbl,
              ceDurationMs = mDur,
              ceStagingOverride = mStg
            }

    decStats m =
      let mBusy = case M.lookup "playerStatsSummaryBusy" m of
            Just (JObj bm) ->
              let sec = jFieldDef 0 jDouble "busySummarySeconds" bm
               in Just $
                    BusyInfo
                      (jFieldDef "" jText "busySummaryAction" bm)
                      (jFieldDef "" jText "busySummaryTarget" bm)
                      (jFieldDef 0 jInt "busySummaryCompleted" bm)
                      (jFieldDef 0 jInt "busySummaryRemaining" bm)
                      sec
                      (jFieldDef (max 0.5 sec) jDouble "busySummaryStepSeconds" bm)
            _ -> Nothing
       in PlayerStatsInfo
            { psHp = jFieldDef 100 jInt "playerStatsSummaryHp" m,
              psMaxHp = max 1 (jFieldDef 100 jInt "playerStatsSummaryMaxHp" m),
              psQi = jFieldDef 100 jInt "playerStatsSummaryQi" m,
              psMaxQi = max 1 (jFieldDef 100 jInt "playerStatsSummaryMaxQi" m),
              psJing = jFieldDef 100 jInt "playerStatsSummaryJing" m,
              psMaxJing = max 1 (jFieldDef 100 jInt "playerStatsSummaryMaxJing" m),
              psAp = jFieldDef 0 jInt "playerStatsSummaryAp" m,
              psStatus = jFieldDef "normal" jText "playerStatsSummaryStatus" m,
              psGender = jFieldDef "male" jText "playerStatsSummaryGender" m,
              psAppearance = jFieldDef 5 jInt "playerStatsSummaryAppearance" m,
              psAppearanceText = jFieldDef "" jText "playerStatsSummaryAppearanceText" m,
              psPortraitKey = jFieldDef "beauty-score-06" jText "playerStatsSummaryPortraitKey" m,
              psStrength = jFieldDef 18 jInt "playerStatsSummaryStrength" m,
              psAgility = jFieldDef 18 jInt "playerStatsSummaryAgility" m,
              psVitality = jFieldDef 18 jInt "playerStatsSummaryVitality" m,
              psPotential = jFieldDef 0 jInt "playerStatsSummaryPotential" m,
              psCombatExp = jFieldDef 0 jInt "playerStatsSummaryCombatExp" m,
              psInjuredSeconds = jFieldDef 0 jInt "playerStatsSummaryInjuredSeconds" m,
              psCombatInsight = jFieldDef 0 jInt "playerStatsSummaryCombatInsight" m,
              psBusy = mBusy
            }

    decInv (JObj m) =
      Just $
        InvItem
          { iiId = jFieldDef "" jText "inventoryItemSummaryId" m,
            iiName = jFieldDef "" jText "inventoryItemSummaryName" m,
            iiAmount = jFieldDef 1 jInt "inventoryItemSummaryAmount" m,
            iiUsable = jFieldDef False jBool "inventoryItemSummaryUsable" m,
            iiStudyable = jFieldDef False jBool "inventoryItemSummaryStudyable" m,
            iiEquipped = jFieldDef False jBool "inventoryItemSummaryEquipped" m,
            iiEquipSlot = jFieldMaybe jText "inventoryItemSummaryEquipSlot" m
          }
    decInv _ = Nothing

    decArt (JObj m) =
      Just $
        ArtInfo
          { aiId = jFieldDef "" jText "artSummaryId" m,
            aiName = jFieldDef "" jText "artSummaryName" m,
            aiType = jFieldDef "" jText "artSummaryType" m,
            aiTier = jFieldDef "" jText "artSummaryTier" m,
            aiLevel = jFieldDef 1 jInt "artSummaryLevel" m,
            aiProgress = jFieldDef 0 jInt "artSummaryProgress" m,
            aiNextProgress = jFieldDef 0 jInt "artSummaryNextProgress" m,
            aiMaxLevel = jFieldDef 100 jInt "artSummaryMaxLevel" m,
            aiIsFoundation = jFieldDef False jBool "artSummaryIsFoundation" m,
            aiEnabled = jFieldDef False jBool "artSummaryEnabled" m,
            aiResearchFrom = jFieldDef 9999 jInt "artSummaryResearchFrom" m,
            aiNextCombatExp = jFieldDef 0 jInt "artSummaryNextCombatExp" m,
            aiBlocker = jFieldMaybe jText "artSummaryBlocker" m,
            aiUnlockedMoves = fromMaybe [] (jField (jList jText) "artSummaryUnlockedAttackMoves" m),
            aiUnlockedSkills = fromMaybe [] (jField (jList jText) "artSummaryUnlockedActiveSkills" m)
          }
    decArt _ = Nothing

    decReward (JObj m) =
      Just $
        RewardInfo
          (jFieldDef "" jText "rewardSummaryKind" m)
          (jFieldDef "奖励" jText "rewardSummaryName" m)
          (jFieldDef 1 jInt "rewardSummaryAmount" m)
    decReward _ = Nothing

    decQuest (JObj m) =
      Just $
        QuestItem
          { qiId = jFieldDef "" jText "questLogEntryId" m,
            qiName = jFieldDef "" jText "questLogEntryName" m,
            qiStage = jFieldDef "" jText "questLogEntryStage" m,
            qiObjective = jFieldMaybe jText "questLogEntryObjective" m,
            qiCompleted = jFieldDef False jBool "questLogEntryCompleted" m,
            qiRewards = maybe [] (mapMaybe decReward) (jField (jList Just) "questLogEntryRewards" m)
          }
    decQuest _ = Nothing

    decBonus (JObj m) =
      CreationBonus
        (jFieldDef 0 jInt "strength" m)
        (jFieldDef 0 jInt "agility" m)
        (jFieldDef 0 jInt "vitality" m)
        (jFieldDef 0 jInt "maxQi" m)
        (jFieldDef 0 jInt "appearance" m)
    decBonus _ = emptyBonus

    decCreationConfig m =
      let baseB = maybe emptyBonus decBonus (M.lookup "baseStats" m)
          genders =
            [ (jFieldDef "male" jText "id" gm, jFieldDef "男" jText "label" gm)
              | JObj gm <- fromMaybe [] (jField (jList Just) "genders" m)
            ]
          decOpt (JObj om) =
            Just $
              CreationOption
                (jFieldDef "" jText "id" om)
                (jFieldDef "" jText "label" om)
                (jFieldDef "" jText "story" om)
                (maybe emptyBonus decBonus (M.lookup "bonus" om))
          decOpt _ = Nothing
       in CreationConfig
            { cfgBaseStats = baseB,
              cfgGenders = genders,
              cfgOrigins = maybe [] (mapMaybe decOpt) (jField (jList Just) "origins" m),
              cfgChildhood1 = maybe [] (mapMaybe decOpt) (jField (jList Just) "childhood1" m),
              cfgChildhood2 = maybe [] (mapMaybe decOpt) (jField (jList Just) "childhood2" m)
            }
