{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Lens
import Control.Monad (replicateM_, unless)
import Control.Monad.Except (throwError)
import Control.Monad.Random (mkStdGen, runRand)
import Data.Aeson (eitherDecode)
import Data.List (findIndex)
import Data.Maybe (fromMaybe, isNothing, listToMaybe)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Text as T
import Database
import Game.CharacterCreation
import Game.Combat
import Game.Entity
import Game.Message
import Game.Progression
import Game.Quest
import Game.World
import GamePlay
import GameState
import Networking
import Utils

main :: IO ()
main = do
  testWorldValidationCatchesBrokenQuestRefs
  testWorldValidationCatchesBrokenRoomExit
  testWorldValidationCatchesUngatedRegionalArt
  testRandomSelectEmpty
  testDefaultFoundationArts
  testCharacterCreationChoiceAppliesInitialAttrs
  testLoginAcceptsMissingCreation
  testLoginAcceptsCreation
  testDefaultTrialSwordAnimation
  testDerivedStats
  testMoveUpdatesRoomOccupancy
  testCrossMapExitMovesPlayerBetweenMaps
  testMapOverviewIncludesCurrentMapGraph
  testCannotAttackAcrossRooms
  testNpcBattleLockBlocksConcurrentAttackAndRespawns
  testDefeatDoesNotKillNpc
  testBattleSettlementMarksPlayerDirty
  testActiveSkillFailureIsSpecific
  testActiveSkillIgnoresApAndSendsSnapshot
  testActiveSkillQueuesDuringActionLock
  testNormalAttackUsesCombatPipeline
  testMultiHitActionSplitsDamageAndLocksApproach
  testBattleActionTickDoesNotSyncApOnly
  testBattleMaintenanceDoesNotNaturallyRecoverHpOrQi
  testBattleActionLockBlocksApGrowth
  testDotEffectTicks
  testTrainRaisesFoundationAndUnlocksActiveSkills
  testProgressionFormulas
  testProgressionActions
  testBattleAndQuestGrowthRewards
  testTrainingQueue
  testJingRequirementFailure
  testJingTickRecovery
  testOutOfCombatRecovery
  testDefeatLeavesPlayerInjured
  testLearningRequirementFailure
  testTeacherRequiresStoryFlag
  testStoryConditionsAndRoomVariants
  testArtsQuery
  testWeiyuanChapterFlow
  testKaifengSettlingAndTravelFlow
  testKaifengJianghuFlow
  testKaifengInterleavedQuestsAndChoices
  testRegionalQuestsAndWeiyuanEchoConvergence
  testStoryBattlesArePlayerIsolated
  testRepeatableJobsAndStreaks
  testShopEquipmentMedicineAndWeaponStyle
  testRoomAndCombatInsightBonuses
  testInternalArtDifferentiation
  testPlayerSaveRoundTrip
  testLegacyPreparedSlotFoldsIntoEnabled
  putStrLn "All tests passed"

assert :: Bool -> String -> IO ()
assert condition message =
  unless condition $ fail message

loadFreshState :: IO GameState
loadFreshState = do
  result <- loadGameState "resources/scripts"
  case result of
    Left err -> fail $ "Failed to load game state: " <> show err
    Right gs -> pure gs

runOk :: String -> GameState -> GameStateT a -> IO ([PlayerResp], GameState)
runOk label gs action = do
  result <- runGameState gs action
  case result of
    Left err -> fail $ label <> " failed: " <> show err
    Right ok -> pure ok

requireResponseIndex :: String -> (ActionResp -> Bool) -> [PlayerResp] -> IO Int
requireResponseIndex label predicate responses =
  case findIndex (predicate . snd) responses of
    Nothing -> fail $ "missing response: " <> label
    Just index -> pure index

newTestPlayerState :: IO GameState
newTestPlayerState = do
  gs <- loadFreshState
  snd <$> runOk "create default player" gs (createDefaultPlayer "tester" "resources/scripts/default_player.yaml")

enableStarterFistForTester :: GameState -> GameState
enableStarterFistForTester =
  players . ix "tester" . playerCharacter . charEnabled . at Fist ?~ ArtEntity "nameless_trial_fist" 1 0

roomPlayersAtMap :: MapId -> GameState -> (Int, Int) -> S.Set PlayerId
roomPlayersAtMap targetMapId gs pos =
  case M.lookup targetMapId (gs ^. world . maps) >>= M.lookup pos . view mapRooms of
    Nothing -> S.empty
    Just room -> room ^. roomPlayer

roomPlayersAt :: GameState -> (Int, Int) -> S.Set PlayerId
roomPlayersAt = roomPlayersAtMap "weiyuan_road"

testCombatNpcId :: CharId
testCombatNpcId = "weiyuan_training_dummy"

withCombatNpcInStarterRoom :: GameState -> GameState
withCombatNpcInStarterRoom =
  world . maps . ix "weiyuan_road" . mapRooms . ix (3, 3) . roomChar %~ addNpc
  where
    addNpc npcs =
      if testCombatNpcId `elem` npcs
        then npcs
        else testCombatNpcId : npcs

withStarterExit :: Direction -> RoomRef -> GameState -> GameState
withStarterExit direction roomRef =
  world . maps . ix "weiyuan_road" . mapRooms . ix (3, 3) . roomExits . at direction ?~ roomRef

withStarterRoadRoundTrip :: GameState -> GameState
withStarterRoadRoundTrip =
  (world . maps . ix "weiyuan_road" . mapRooms . ix (3, 3) . roomExits . at East ?~ RoomRef "bianshui_road" (0, 0))
    . (world . maps . ix "bianshui_road" . mapRooms . ix (0, 0) . roomExits . at West ?~ RoomRef "weiyuan_road" (3, 3))

getNpc :: GameState -> IO Character
getNpc gs =
  case M.lookup testCombatNpcId (gs ^. world . chars) of
    Nothing -> fail "test combat NPC missing"
    Just npc -> pure npc

getBattle :: GameState -> IO Battle
getBattle gs =
  case M.lookup "tester" (gs ^. battles) of
    Nothing -> fail "tester battle missing"
    Just battle -> pure battle

startTrainingBattle :: GameState -> IO ([PlayerResp], GameState)
startTrainingBattle gs = do
  runOk "start training battle" (withCombatNpcInStarterRoom gs) (playerAttack "tester" testCombatNpcId)

questStageOf :: QuestId -> GameState -> Maybe QuestStage
questStageOf quest gs =
  M.lookup "tester" (gs ^. stories) >>= M.lookup quest . view storyQuestStages

knownArtLevel :: ArtId -> Player -> Maybe Int
knownArtLevel targetArtId player =
  case artLevels of
    [] -> Nothing
    _ -> Just $ maximum artLevels
  where
    artLevels =
      [ known ^. artLevel
        | knownArts <- M.elems $ player ^. playerCharacter . charArt,
          known <- knownArts,
          known ^. artDef == targetArtId
      ]

knowsArtAt :: ArtId -> Int -> Player -> Bool
knowsArtAt targetArtId expectedLevel player =
  knownArtLevel targetArtId player == Just expectedLevel

enabledArtIn :: ArtType -> ArtId -> Player -> Bool
enabledArtIn artType' expectedId player =
  maybe False ((== expectedId) . view artDef) (player ^. playerCharacter . charEnabled . at artType')

testWorldValidationCatchesBrokenQuestRefs :: IO ()
testWorldValidationCatchesBrokenQuestRefs = do
  gs <- loadFreshState
  case [(qid, quest) | (qid, quest) <- M.toList (gs ^. world . quests), not (null $ quest ^. questEvents)] of
    [] -> fail "test fixture has no quest events to corrupt"
    (qid, _) : _ -> do
      let broken =
            gs
              ^. world
              & quests . ix qid . questEvents . ix 0 . questEventActions %~ (++ [StartBattle "missing_npc"])
      case validateWorld broken of
        Left err ->
          assert ("missing_npc" `T.isInfixOf` err) "world validation error did not identify the missing NPC"
        Right _ -> fail "world validation accepted a quest with a missing NPC reference"

testWorldValidationCatchesBrokenRoomExit :: IO ()
testWorldValidationCatchesBrokenRoomExit = do
  gs <- loadFreshState
  case [ (mid, pos, dir)
         | (mid, mp) <- M.toList (gs ^. world . maps),
           (pos, room) <- M.toList (mp ^. mapRooms),
           (dir, _) <- M.toList (room ^. roomExits)
       ] of
    [] -> fail "test fixture has no room exits to corrupt"
    (mid, pos, dir) : _ -> do
      let broken =
            gs
              ^. world
              & maps . ix mid . mapRooms . ix pos . roomExits . ix dir . roomRefMapId .~ "missing_map"
      case validateWorld broken of
        Left err ->
          assert ("missing_map" `T.isInfixOf` err) "world validation error did not identify the missing exit map"
        Right _ -> fail "world validation accepted an exit to a missing room"

testWorldValidationCatchesUngatedRegionalArt :: IO ()
testWorldValidationCatchesUngatedRegionalArt = do
  gs <- loadFreshState
  let broken = gs ^. world & martialArts . ix "luoyang_sword" . artRequires .~ [ArtRequirement "basic_sword" 1]
  case validateWorld broken of
    Left err -> assert ("luoyang_sword" `T.isInfixOf` err) "world validation did not name the ungated regional art"
    Right _ -> fail "world validation accepted a regional art gated at foundation level 1"

testRandomSelectEmpty :: IO ()
testRandomSelectEmpty = do
  let (selected, _) = runRand (randomSelect ([] :: [Int])) (mkStdGen 1)
  assert (selected == Nothing) "randomSelect should return Nothing for an empty list"

testDefaultFoundationArts :: IO ()
testDefaultFoundationArts = do
  gs <- newTestPlayerState
  case M.lookup "tester" (gs ^. players) of
    Nothing -> fail "tester missing"
    Just player -> do
      assert (knowsArtAt "basic_internal" 1 player) "default player is missing basic_internal"
      assert (knowsArtAt "basic_lightness" 1 player) "default player is missing basic_lightness"
      assert (knowsArtAt "basic_sword" 1 player) "default player is missing basic_sword"
      assert (knowsArtAt "basic_fist" 1 player) "default player is missing basic_fist"
      assert (knowsArtAt "nameless_trial_fist" 1 player) "default player is missing the starter fist art"
      assert (knowsArtAt "nameless_trial_sword" 1 player) "default player is missing the starter sword art"
      assert (enabledArtIn Sword "nameless_trial_sword" player) "default player did not enable the starter sword art"
      assert ((player ^. playerCharacter . charEnabled . at Foundation) == Nothing) "foundation art should not be enabled"
      assert ((player ^. playerPotential) == 20) "default player potential did not load"
      assert ((player ^. playerCombatExp) == 0) "new players should start without combat exp"
      assert ((player ^. playerCharacter . charGender) == UnknownGender) "default player gender did not load"
      assert ((player ^. playerCharacter . charAppearance) == 5) "default player appearance did not load"
      assert ((player ^. playerCharacter . charJing) == 120) "default player jing did not load"
      assert ((player ^. playerCharacter . charInnate) == InnateAttrs 18 18 18) "default player innate attrs did not load"

testCharacterCreationChoiceAppliesInitialAttrs :: IO ()
testCharacterCreationChoiceAppliesInitialAttrs = do
  gs <- loadFreshState
  let choice = CharacterCreationChoice Male "martial_family" "river_chase" "breath_lessons"
  (_, gs') <- runOk "create player with character creation" gs (createDefaultPlayerWithCreation "tester" "resources/scripts/default_player.yaml" (Just choice))
  case M.lookup "tester" (gs' ^. players) of
    Nothing -> fail "tester missing"
    Just player -> do
      assert ((player ^. playerCharacter . charInnate) == InnateAttrs 21 22 20) "character creation did not apply innate bonuses"
      assert ((player ^. playerCharacter . charMaxQi) == 124) "character creation did not apply max qi bonus"
      assert ((player ^. playerCharacter . charAppearance) == 7) "character creation did not apply appearance bonus"
      assert ((player ^. playerCharacter . charGender) == Male) "character creation did not apply gender"
      assert ((player ^. playerCharacter . charMaxHP) == (deriveStats player ^. dsMaxHp)) "character creation did not fill max hp"
      assert ((player ^. playerCharacter . charQi) == (deriveStats player ^. dsMaxQi)) "character creation did not fill initial qi"
      assert ("武学世家" `T.isInfixOf` (player ^. playerCharacter . charDesc)) "character creation did not write origin summary"
  case M.lookup "tester" (gs' ^. stories) of
    Nothing -> fail "tester story state missing after character creation"
    Just storyState ->
      assert (S.member "creation.origin.martial_family" $ storyState ^. storyFlags) "character creation origin flag was not recorded"

testLoginAcceptsMissingCreation :: IO ()
testLoginAcceptsMissingCreation =
  case eitherDecode "{\"tag\":\"Login\",\"username\":\"tester\",\"password\":\"\"}" of
    Right Login {username = "tester", password = "", creation = Nothing} -> pure ()
    other -> fail $ "legacy Login JSON did not parse: " <> show (other :: Either String NetEvent)

testLoginAcceptsCreation :: IO ()
testLoginAcceptsCreation = do
  case eitherDecode "{\"tag\":\"Login\",\"username\":\"tester\",\"password\":\"\",\"creation\":{\"gender\":\"female\",\"origin\":\"scholar_house\",\"childhood1\":\"night_reading\",\"childhood2\":\"breath_lessons\"}}" of
    Right Login {username = "tester", password = "", creation = Just (CharacterCreationChoice Female "scholar_house" "night_reading" "breath_lessons")} -> pure ()
    other -> fail $ "Login JSON with gendered creation did not parse: " <> show (other :: Either String NetEvent)
  case eitherDecode "{\"tag\":\"Login\",\"username\":\"tester\",\"password\":\"\",\"creation\":{\"origin\":\"scholar_house\",\"childhood1\":\"night_reading\",\"childhood2\":\"breath_lessons\"}}" of
    Right Login {username = "tester", password = "", creation = Just (CharacterCreationChoice UnknownGender "scholar_house" "night_reading" "breath_lessons")} -> pure ()
    other -> fail $ "legacy Login JSON with creation did not parse: " <> show (other :: Either String NetEvent)

testDefaultTrialSwordAnimation :: IO ()
testDefaultTrialSwordAnimation = do
  gs <- newTestPlayerState
  case M.lookup "tester" (gs ^. players) of
    Nothing -> fail "tester missing"
    Just player ->
      assert (combatStyleForCharacter (player ^. playerCharacter) == "sword") "default test player did not resolve to sword combat style"
  case M.lookup "nameless_trial_sword" (gs ^. world . martialArts) of
    Nothing -> fail "nameless_trial_sword missing"
    Just martialArt -> do
      let moves = martialArt ^. artAttackMoves
          moveActions = map (view $ attackMoveAnimation . animationRefAction) moves
      assert (not $ null moves) "nameless_trial_sword has no attack moves"
      assert (moveActions == ["rig.sword.thrust_a", "rig.sword.chop_a", "rig.sword.rising_cut_a"]) "trial sword moves are not bound to their fixed rig actions"
  npc <- getNpc gs
  assert (combatStyleForCharacter npc == "sword") "training dummy did not resolve to sword combat style"

testDerivedStats :: IO ()
testDerivedStats = do
  gs <- newTestPlayerState
  case M.lookup "tester" (gs ^. players) of
    Nothing -> fail "tester missing"
    Just player -> do
      let derived = deriveStats player
      assert ((derived ^. dsMaxHp) == 170) "derived max hp changed unexpectedly"
      assert ((derived ^. dsMaxQi) == 136) "derived max qi changed unexpectedly"
      assert ((derived ^. dsMaxJing) == 152) "derived max jing changed unexpectedly"
      assert ((derived ^. dsLoadLimit) == 47100) "derived load limit changed unexpectedly"
      let ironBody =
            ActiveEffect
              { _activeEffectDef = "iron_body_buff",
                _activeEffectRemaining = 10.0,
                _activeEffectValue = 5
              }
          withStatus =
            deriveCharacterStats
              (player ^. playerCharacter)
              (player ^. playerCombatExp)
              (characterDerivedStatSources (gs ^. world . effects) (M.singleton "iron_body_buff" ironBody) (player ^. playerCharacter))
      assert ((withStatus ^. dsStrength) == 23) "status modifier did not affect derived strength"
      assert ((withStatus ^. dsDamageReduction) > (derived ^. dsDamageReduction)) "status modifier did not affect mitigation"

testMoveUpdatesRoomOccupancy :: IO ()
testMoveUpdatesRoomOccupancy = do
  gs <- withStarterExit North (RoomRef "kaifeng_city" (0, -3)) <$> newTestPlayerState
  (_, atKaifengEntry) <- runOk "move north to Kaifeng entry" gs (playerMove "tester" North)
  (_, moved) <- runOk "move north inside Kaifeng" atKaifengEntry (playerMove "tester" North)
  assert (not $ S.member "tester" (roomPlayersAtMap "kaifeng_city" moved (0, -3))) "player remained in the old room after moving"
  assert (S.member "tester" (roomPlayersAtMap "kaifeng_city" moved (0, -2))) "player was not added to the new room after moving"

testCrossMapExitMovesPlayerBetweenMaps :: IO ()
testCrossMapExitMovesPlayerBetweenMaps = do
  gs <- withStarterRoadRoundTrip <$> newTestPlayerState
  (responses, inMountainPass) <- runOk "move east to official road" gs (playerMove "tester" East)
  case M.lookup "tester" (inMountainPass ^. players) of
    Nothing -> fail "tester missing after cross-map movement"
    Just player ->
      assert ((player ^. playerPosition) == ("bianshui_road", (0, 0))) "player position did not switch to the target map"
  assert (not $ S.member "tester" (roomPlayersAt inMountainPass (3, 3))) "player remained in the source map room"
  assert (S.member "tester" (roomPlayersAtMap "bianshui_road" inMountainPass (0, 0))) "player was not added to the target map room"
  case [exits | (_, ViewMsg _ _ _ exits) <- responses] of
    [] -> fail "cross-map movement did not send a room view"
    exits : _ ->
      assert
        (any (\exit -> roomExitSummaryMapId exit == "weiyuan_road" && roomExitSummaryPosition exit == (3, 3)) exits)
        "target room view did not preserve the cross-map return exit"

  (_, returned) <- runOk "return west to test map" inMountainPass (playerMove "tester" West)
  case M.lookup "tester" (returned ^. players) of
    Nothing -> fail "tester missing after returning from cross-map movement"
    Just player ->
      assert ((player ^. playerPosition) == ("weiyuan_road", (3, 3))) "player did not return to the source map"

testMapOverviewIncludesCurrentMapGraph :: IO ()
testMapOverviewIncludesCurrentMapGraph = do
  gs <- newTestPlayerState
  (responses, _) <- runOk "map overview" gs (playerMapOverview "tester")
  case [overview | (_, MapOverviewMsg overview) <- responses] of
    [overview] -> do
      currentMap <-
        case M.lookup (mapOverviewSummaryMapId overview) (gs ^. world . maps) of
          Nothing -> fail "current map missing from world fixture"
          Just mp -> pure mp
      assert (mapOverviewSummaryMapId overview == "weiyuan_road") "map overview did not use the player's current map"
      assert (mapOverviewSummaryMapName overview == currentMap ^. mapName) "map overview did not include the map name"
      assert (mapOverviewSummaryCurrentPosition overview == (3, 3)) "map overview did not include the player's current position"
      assert
        (map mapRoomSummaryRoomId (mapOverviewSummaryRooms overview) == map (view roomId . snd) (M.toAscList $ currentMap ^. mapRooms))
        "map overview did not include every room in coordinate order"
      let expectedLocalEdges =
            [ ()
              | (fromPosition, room) <- M.toList (currentMap ^. mapRooms),
                (_direction, exitRef) <- M.toList (room ^. roomExits),
                exitRef ^. roomRefMapId == mapOverviewSummaryMapId overview,
                M.member fromPosition (currentMap ^. mapRooms)
            ]
      assert
        (length (mapOverviewSummaryEdges overview) == length expectedLocalEdges)
        "map overview did not include the expected local edges"
      assert
        (not $ any ((== (0, 0)) . mapEdgeSummaryToPosition) (mapOverviewSummaryEdges overview))
        "map overview should not include cross-map edges in the current map graph"
    [] -> fail "map overview did not send MapOverviewMsg"
    _ -> fail "map overview sent multiple MapOverviewMsg responses"

testCannotAttackAcrossRooms :: IO ()
testCannotAttackAcrossRooms = do
  gs <- withStarterExit East (RoomRef "bianshui_road" (0, 0)) . withCombatNpcInStarterRoom <$> newTestPlayerState
  (_, moved) <- runOk "move east" gs (playerMove "tester" East)
  result <- runGameState moved (playerAttack "tester" testCombatNpcId)
  case result of
    Left (UnableToInteract _ Attacking) -> pure ()
    Left err -> fail $ "expected UnableToInteract Attacking, got: " <> show err
    Right _ -> fail "player attacked an NPC from a different room"

testNpcBattleLockBlocksConcurrentAttackAndRespawns :: IO ()
testNpcBattleLockBlocksConcurrentAttackAndRespawns = do
  gs <- loadFreshState
  (_, withTester) <- runOk "create tester" gs (createDefaultPlayer "tester" "resources/scripts/default_player.yaml")
  (_, withRival) <- runOk "create rival" withTester (createDefaultPlayer "rival" "resources/scripts/default_player.yaml")
  let withCombatNpc = withCombatNpcInStarterRoom withRival
  (_, locked) <- runOk "tester starts npc battle" withCombatNpc (playerAttack "tester" testCombatNpcId)
  npcLocked <- getNpc locked
  assert ((npcLocked ^. charStatus) == CharBattle) "NPC was not locked when battle started"

  concurrentAttack <- runGameState locked (playerAttack "rival" testCombatNpcId)
  case concurrentAttack of
    Left (UnableToInteract _ Attacking) -> pure ()
    Left err -> fail $ "expected concurrent NPC attack to be blocked, got: " <> show err
    Right _ -> fail "second player started a battle against a locked NPC"

  let defeatedPlayer =
        locked
          & battles . ix "tester" . battleState . battleChar . charHP .~ 0
  (_, released) <- runOk "tester loses and releases npc" defeatedPlayer (updateBattle 0 "tester")
  npcReleased <- getNpc released
  assert ((npcReleased ^. charStatus) == CharAlive) "NPC lock was not released after player defeat"

  (_, rivalBattle) <- runOk "rival starts npc battle after release" released (playerAttack "rival" testCombatNpcId)
  npcLockedAgain <- getNpc rivalBattle
  assert ((npcLockedAgain ^. charStatus) == CharBattle) "NPC was not locked for the second battle"

  let defeatedEnemy =
        rivalBattle
          & battles . ix "rival" . battleEnemyState . battleChar . charHP .~ 0
  (_, dead) <- runOk "rival kills npc" defeatedEnemy (updateBattle 0 "rival")
  npcDead <- getNpc dead
  assert ((npcDead ^. charStatus) == CharDead) "NPC did not stay dead after being killed"

  attackDeadNpc <- runGameState dead (playerAttack "tester" testCombatNpcId)
  case attackDeadNpc of
    Left (UnableToInteract _ Attacking) -> pure ()
    Left err -> fail $ "expected dead NPC attack to be blocked, got: " <> show err
    Right _ -> fail "player attacked a dead NPC before respawn"

  (_, respawned) <- runOk "respawn locked npc" dead (tickRespawns 5)
  npcRespawned <- getNpc respawned
  let npcStats = deriveCharacterStats npcRespawned 0 emptyDerivedStatSources
  assert ((npcRespawned ^. charStatus) == CharAlive) "NPC did not respawn as alive"
  assert ((npcRespawned ^. charHP) == npcStats ^. dsMaxHp) "NPC did not respawn at full HP"
  assert ((npcRespawned ^. charQi) == npcStats ^. dsMaxQi) "NPC did not respawn at full Qi"

testDefeatDoesNotKillNpc :: IO ()
testDefeatDoesNotKillNpc = do
  gs <- newTestPlayerState
  (_, inBattle) <- startTrainingBattle gs
  let defeated =
        inBattle
          & battles . ix "tester" . battleState . battleChar . charHP .~ 0
  (_, settled) <- runOk "settle defeated battle" defeated (updateBattle 0 "tester")
  assert (M.notMember "tester" (settled ^. battles)) "battle was not cleared after defeat"
  npc <- getNpc settled
  assert ((npc ^. charStatus) == CharAlive) "NPC was killed when the player lost"
  assert (M.notMember testCombatNpcId (settled ^. respawn)) "NPC respawn was scheduled when the player lost"
  case M.lookup "tester" (settled ^. players) of
    Nothing -> fail "tester missing after defeat"
    Just player -> do
      assert ((player ^. playerStatus) == PlayerNormal) "player was not returned to normal status after defeat"
      assert ((player ^. playerCharacter . charHP) == 1) "defeated player should be left at 1 HP"

testBattleSettlementMarksPlayerDirty :: IO ()
testBattleSettlementMarksPlayerDirty = do
  gs <- newTestPlayerState
  (_, inBattle) <- startTrainingBattle gs
  (_, ticking) <- runOk "ordinary battle tick" inBattle (updateBattle 0 "tester")
  assert (S.notMember "tester" (ticking ^. dirtyPlayers)) "ordinary battle tick should not mark the player dirty"
  let defeatedEnemy =
        inBattle
          & battles . ix "tester" . battleEnemyState . battleChar . charHP .~ 0
  (_, settled) <- runOk "settle won battle" defeatedEnemy (updateBattle 0 "tester")
  assert (S.member "tester" (settled ^. dirtyPlayers)) "battle settlement did not mark the player dirty"

testActiveSkillFailureIsSpecific :: IO ()
testActiveSkillFailureIsSpecific = do
  gs <- enableStarterFistForTester <$> newTestPlayerState
  (_, inBattle) <- startTrainingBattle gs
  let drained =
        inBattle
          & battles . ix "tester" . battleState . battleQi .~ 0
  (responses, _) <- runOk "perform active skill without qi" drained (playerPerformActiveSkill "tester" "power_strike")
  assert
    (any (\(_, resp) -> resp == ActiveSkillFailureMsg (ActiveSkillNeedQi 30 0)) responses)
    "active skill failure did not report the specific Qi requirement"

testActiveSkillIgnoresApAndSendsSnapshot :: IO ()
testActiveSkillIgnoresApAndSendsSnapshot = do
  gs <- enableStarterFistForTester <$> newTestPlayerState
  (_, inBattle) <- startTrainingBattle gs
  let ready =
        inBattle
          & battles . ix "tester" . battleState . battleAp .~ 0
  (responses, afterSkill) <- runOk "perform power strike" ready (playerPerformActiveSkill "tester" "power_strike")
  battle <- getBattle afterSkill
  assert ((battle ^. battleState . battleAp) == 0) "active skill changed AP"
  assert ((battle ^. battleState . battleQi) == 70) "active skill did not consume Qi"
  assert ((battle ^. battleEnemyState . battleChar . charHP) == 77) "active skill did not apply derived damage"
  assert (any isActiveSkillEvent responses) "active skill success did not emit a combat event"
  assert (any (isBattleStateMsg . snd) responses) "active skill success did not send a battle snapshot"
  where
    isActiveSkillEvent (_, CombatEventMsg event) =
      combatEventKind event == CombatEventActiveSkill
        && not (T.null $ combatEventActorName event)
        && not (T.null $ combatEventTargetName event)
        && combatEventDamage event == Just 37
        && not (T.null $ combatEventVisual event ^. combatVisualActionId)
    isActiveSkillEvent _ = False

    isBattleStateMsg (BattleStateMsg _) = True
    isBattleStateMsg _ = False

testActiveSkillQueuesDuringActionLock :: IO ()
testActiveSkillQueuesDuringActionLock = do
  gs <- enableStarterFistForTester <$> newTestPlayerState
  (_, inBattle) <- startTrainingBattle gs
  let locked =
        inBattle
          & battles . ix "tester" . battleState . battleAp .~ 0
          & battles . ix "tester" . battleActionLockRemaining .~ 0.5
  (queueResponses, queued) <- runOk "queue skill while action lock is active" locked (playerPerformActiveSkill "tester" "power_strike")
  queuedBattle <- getBattle queued
  assert (not $ any (isCombatEvent . snd) queueResponses) "queued active skill executed before action lock expired"
  assert (queuedBattle ^. battlePendingActiveSkill /= Nothing) "active skill was not queued during action lock"
  assert ((queuedBattle ^. battleState . battleQi) == 100) "queued active skill consumed Qi before execution"

  (blockedResponses, stillQueued) <- runOk "tick before queued skill can fire" queued (onBattleTick 0.25)
  stillQueuedBattle <- getBattle stillQueued
  assert (null blockedResponses) "locked queued skill tick emitted responses too early"
  assert (stillQueuedBattle ^. battlePendingActiveSkill /= Nothing) "queued active skill fired before lock expired"

  (skillResponses, afterSkill) <- runOk "release queued active skill" stillQueued (onBattleTick 0.5)
  battle <- getBattle afterSkill
  assert (any isActiveSkillEvent skillResponses) "queued active skill did not emit a combat event"
  assert (battle ^. battlePendingActiveSkill == Nothing) "queued active skill was not cleared"
  assert ((battle ^. battleState . battleAp) == 0) "queued active skill changed AP"
  assert ((battle ^. battleState . battleQi) == 70) "queued active skill did not consume Qi on execution"
  assert ((battle ^. battleEnemyState . battleChar . charHP) == 77) "queued active skill did not apply damage"
  assert ((battle ^. battleActionLockRemaining) > 0) "queued active skill did not set an action lock"
  where
    isCombatEvent (CombatEventMsg _) = True
    isCombatEvent _ = False

    isActiveSkillEvent (_, CombatEventMsg event) =
      combatEventKind event == CombatEventActiveSkill
    isActiveSkillEvent _ = False

testNormalAttackUsesCombatPipeline :: IO ()
testNormalAttackUsesCombatPipeline = do
  gs <- newTestPlayerState
  (_, inBattle) <- startTrainingBattle gs
  let ready =
        inBattle
          & battles . ix "tester" . battleState . battleAp .~ 100
          & battles . ix "tester" . battleState . battleChar . charInnate . innateStrength .~ 60
          & battles . ix "tester" . battleEnemyState . battleEffects . at "weakened" ?~ ActiveEffect "weakened" 5.0 100
          & battles . ix "tester" . battleEnemyState . battleChar . charEnabled .~ M.empty
  (responses, afterTick) <- runOk "normal attack pipeline tick" ready (updateBattle 0 "tester")
  let combatDamages =
        [ dmg
          | (_, CombatEventMsg event) <- responses,
            Just dmg <- [combatEventDamage event],
            dmg > 0
        ]
  case combatDamages of
    [] -> fail "normal attack pipeline did not emit a damaging combat message"
    damage : _ -> do
      expectedDamages <- expectedNormalAttackDamages ready
      assert (damage `elem` expectedDamages) "normal attack damage did not use derived strength and mitigation"
      battle <- getBattle afterTick
      assert ((battle ^. battleEnemyState . battleChar . charHP) == 114 - damage) "normal attack damage was not applied to the enemy"

testMultiHitActionSplitsDamageAndLocksApproach :: IO ()
testMultiHitActionSplitsDamageAndLocksApproach = do
  assert (splitByShares 18 [1, 1, 2] == [5, 4, 9]) "hit shares must split like the client"
  assert (sum (splitByShares 7 [1, 1, 1]) == 7) "hit shares must preserve the total"
  gs <- newTestPlayerState
  case M.lookup "rig.fist.combo_a" (gs ^. world . combatActionTimings) of
    Nothing -> fail "combo action timing was not loaded from the manifest"
    Just timing -> do
      assert ((timing ^. combatActionTimingApproachMs) == 280) "approach duration was not read from the manifest"
      assert ((timing ^. combatActionTimingHitShares) == [1, 1, 2]) "hit shares were not read from the manifest"
  let comboWorld = gs & world . martialArts . traverse . artAttackMoves . traverse . attackMoveAnimation . animationRefAction .~ "rig.fist.combo_a"
  (_, inBattle) <- startTrainingBattle comboWorld
  let ready =
        inBattle
          & battles . ix "tester" . battleState . battleAp .~ 100
          & battles . ix "tester" . battleEnemyState . battleAp .~ 0
          & battles . ix "tester" . battleActionLockRemaining .~ 0
  enemyHpBefore <- (^. battleEnemyState . battleChar . charHP) <$> getBattle ready
  (responses, afterTick) <- runOk "multi-hit attack tick" ready (updateBattle 0 "tester")
  let comboEvents = [event | (_, CombatEventMsg event) <- responses, length (combatEventHits event) == 3]
  case comboEvents of
    [] -> fail "multi-hit attack did not report three hit outcomes"
    event : _ -> do
      let landed = sum [damage | CombatHitOutcome CombatHit (Just damage) _ <- combatEventHits event]
      assert (combatEventDamage event == Just landed) "event damage must equal the landed hits"
      battle <- getBattle afterTick
      assert ((battle ^. battleEnemyState . battleChar . charHP) == enemyHpBefore - landed) "landed hits were not applied to the enemy"
      assert ((battle ^. battleActionLockRemaining) >= 1.0) "action lock must cover the approach plus the clip"

testBattleActionTickDoesNotSyncApOnly :: IO ()
testBattleActionTickDoesNotSyncApOnly = do
  gs <- newTestPlayerState
  (_, inBattle) <- startTrainingBattle gs
  (responses, afterTick) <- runOk "fast battle ap-only tick" inBattle (onBattleTick 0.05)
  battle <- getBattle afterTick
  assert (null responses) "AP-only battle tick should not send responses"
  assert ((battle ^. battleState . battleAp) > 0) "fast battle tick did not accumulate player AP"
  assert ((battle ^. battleEnemyState . battleAp) > 0) "fast battle tick did not accumulate enemy AP"

testBattleMaintenanceDoesNotNaturallyRecoverHpOrQi :: IO ()
testBattleMaintenanceDoesNotNaturallyRecoverHpOrQi = do
  gs <- newTestPlayerState
  (_, inBattle) <- startTrainingBattle gs
  let wounded =
        inBattle
          & battles . ix "tester" . battleState . battleChar . charHP .~ 40
          & battles . ix "tester" . battleState . battleQi .~ 10
          & battles . ix "tester" . battleEnemyState . battleChar . charHP .~ 50
          & battles . ix "tester" . battleEnemyState . battleQi .~ 12
  (_, afterTick) <- runOk "battle maintenance without natural recovery" wounded (tickBattleMaintenance 1)
  battle <- getBattle afterTick
  assert ((battle ^. battleState . battleChar . charHP) == 40) "player HP naturally recovered during battle"
  assert ((battle ^. battleState . battleQi) == 10) "player Qi naturally recovered during battle"
  assert ((battle ^. battleEnemyState . battleChar . charHP) == 50) "enemy HP naturally recovered during battle"
  assert ((battle ^. battleEnemyState . battleQi) == 12) "enemy Qi naturally recovered during battle"

testBattleActionLockBlocksApGrowth :: IO ()
testBattleActionLockBlocksApGrowth = do
  gs <- newTestPlayerState
  (_, inBattle) <- startTrainingBattle gs
  let ready =
        inBattle
          & battles . ix "tester" . battleState . battleAp .~ 100
          & battles . ix "tester" . battleEnemyState . battleAp .~ 20
  (actionResponses, locked) <- runOk "trigger normal attack lock" ready (onBattleTick 0)
  assert (any (isCombatEvent . snd) actionResponses) "ready combatant did not emit an action"
  lockedBattle <- getBattle locked
  let playerApAfterAction = lockedBattle ^. battleState . battleAp
      enemyApAfterAction = lockedBattle ^. battleEnemyState . battleAp
      lockRemaining = lockedBattle ^. battleActionLockRemaining
  assert (lockRemaining > 0) "normal attack did not set an action lock"

  (blockedResponses, blocked) <- runOk "tick during action lock" locked (onBattleTick 0.05)
  blockedBattle <- getBattle blocked
  assert (null blockedResponses) "action-locked tick should not emit responses"
  assert ((blockedBattle ^. battleState . battleAp) == playerApAfterAction) "player AP grew during action lock"
  assert ((blockedBattle ^. battleEnemyState . battleAp) == enemyApAfterAction) "enemy AP grew during action lock"
  assert ((blockedBattle ^. battleActionLockRemaining) < lockRemaining) "action lock did not tick down"

  (_, resumed) <- runOk "tick after action lock" blocked (onBattleTick (lockRemaining + 0.2))
  resumedBattle <- getBattle resumed
  assert ((resumedBattle ^. battleActionLockRemaining) == 0) "action lock did not expire"
  assert
    ((resumedBattle ^. battleState . battleAp) > playerApAfterAction || (resumedBattle ^. battleEnemyState . battleAp) > enemyApAfterAction)
    "AP did not resume after action lock expired"
  where
    isCombatEvent (CombatEventMsg _) = True
    isCombatEvent _ = False

expectedNormalAttackDamages :: GameState -> IO [Int]
expectedNormalAttackDamages gs = do
  battle <- getBattle gs
  let effectDefs = gs ^. world . effects
      attackerState = battle ^. battleState
      defenderState = battle ^. battleEnemyState
      attackerChar = attackerState ^. battleChar
      defenderChar = defenderState ^. battleChar
      attackerStats =
        deriveCharacterStats
          attackerChar
          (attackerState ^. battleCombatExp)
          (characterDerivedStatSources effectDefs (attackerState ^. battleEffects) attackerChar)
      defenderStats =
        deriveCharacterStats
          defenderChar
          (defenderState ^. battleCombatExp)
          (characterDerivedStatSources effectDefs (defenderState ^. battleEffects) defenderChar)
  pure $
    [ computeDamage attackerStats defenderStats preparedAttack
      | preparedAttack <- unlockedPreparedAttacks (gs ^. world . martialArts) attackerChar
    ]

testDotEffectTicks :: IO ()
testDotEffectTicks = do
  gs <- newTestPlayerState
  (_, inBattle) <- startTrainingBattle gs
  let bleeding =
        ActiveEffect
          { _activeEffectDef = "bleeding",
            _activeEffectRemaining = 2.0,
            _activeEffectValue = 5
          }
      withBleed =
        inBattle
          & battles . ix "tester" . battleEnemyState . battleEffects . at "bleeding" ?~ bleeding
  (_, afterTick) <- runOk "tick bleeding" withBleed (updateBattle 1 "tester")
  battle <- getBattle afterTick
  assert ((battle ^. battleEnemyState . battleChar . charHP) == 109) "DoT did not damage the affected combatant"
  case M.lookup "bleeding" (battle ^. battleEnemyState . battleEffects) of
    Nothing -> fail "DoT effect disappeared too early"
    Just effect ->
      assert ((effect ^. activeEffectRemaining) == 1.0) "DoT remaining duration did not tick down"

testTrainRaisesFoundationAndUnlocksActiveSkills :: IO ()
testTrainRaisesFoundationAndUnlocksActiveSkills = do
  gs <- newTestPlayerState
  (_, learned) <- runOk "learn weiyuan sword" gs $ do
    grantArt "tester" "weiyuan_sword" 1
    playerEnableArt "tester" Sword "weiyuan_sword"
  let seasoned =
        learned
          & players . ix "tester" . playerCombatExp .~ 1000
          & players . ix "tester" . playerCharacter . charArt . ix Foundation %~ setArtLevel "basic_sword" 10

  (lowBattleMsgs, _) <- startTrainingBattle seasoned
  let lowActiveSkillIds = battleActiveSkillIds lowBattleMsgs
  assert ("steady_cut" `elem` lowActiveSkillIds) "level 1 weiyuan_sword did not expose steady_cut"
  assert ("eight_direction_thrusts" `notElem` lowActiveSkillIds) "eight_direction_thrusts unlocked before level 5"

  -- 2->5 needs 40+50+60+70 = 220 proficiency at 5 per practice.
  (_, trained) <- runOk "practise weiyuan sword to 5" seasoned $
    replicateM_ 44 (restTester >> practiceStep "tester" "weiyuan_sword")
  player <- requirePlayer trained
  assert (knowsArtAt "weiyuan_sword" 5 player) "practice did not raise weiyuan_sword to level 5"
  assert (knowsArtAt "basic_sword" 10 player) "half the proficiency should not yet lift basic_sword past 10"
  assert (artProgressOf "basic_sword" player == Just 88) "practice did not share proficiency with the foundation"
  assert (enabledArtIn Sword "weiyuan_sword" player) "practice did not keep weiyuan_sword enabled"

  (highBattleMsgs, _) <- startTrainingBattle trained
  let highActiveSkillIds = battleActiveSkillIds highBattleMsgs
  assert ("eight_direction_thrusts" `elem` highActiveSkillIds) "eight_direction_thrusts did not unlock at level 5"
  where
    battleActiveSkillIds responses =
      [ activeSkillSummaryId activeSkill
        | (_, BattleStateMsg snapshot) <- responses,
          activeSkill <- battleSnapshotActiveSkills snapshot
      ]

testProgressionFormulas :: IO ()
testProgressionFormulas = do
  assert (map combatExpRequiredForLevel [1, 2, 10, 30, 100] == [0, 0, 100, 2700, 100000]) "combat exp curve changed"
  assert (map artProgressRequired [2, 10, 30] == [40, 120, 320]) "proficiency curve changed"
  -- Overflow carries into the next level: 1 -> 2 needs 40, 2 -> 3 needs 50.
  assert (addArtProgress 20 1000 Nothing 100 1 0 == (3, 10)) "proficiency overflow did not carry over"
  assert (addArtProgress 20 1000 (Just 2) 100 1 0 == (2, 49)) "source cap did not hold proficiency one short"
  assert (addArtProgress 20 0 Nothing 100 2 0 == (2, 49)) "combat exp gate did not hold proficiency one short"
  assert (addArtProgress 3 1000 Nothing 500 2 0 == (3, 0)) "max level did not clear proficiency"
  assert (canGainProgress 20 0 Nothing 2 10 == Nothing) "a gated art should still fill its bar"
  assert (canGainProgress 20 1000 (Just 2) 2 10 == Just (BlockedBySourceCap 2)) "a source cap should stop the step"
  assert (battleCombatExpGain 10 10 == 10 && battleCombatExpGain 30 10 == 1 && battleCombatExpGain 10 15 == 16) "battle reward scaling changed"
  assert (potentialCap 1000 == 300) "potential cap changed"

testProgressionActions :: IO ()
testProgressionActions = do
  gs <- withCombatNpcInStarterRoom <$> newTestPlayerState
  (_, firstLesson) <- runOk "learn from teacher" gs (playerLearnArt "tester" testCombatNpcId "weiyuan_sword" 2)
  (_, secondLesson) <- runOk "second queued lesson" firstLesson (tickTraining learnBusySeconds)
  let learned = idle secondLesson
  player <- requirePlayer learned
  assert (knowsArtAt "weiyuan_sword" 1 player) "the first lesson should teach level 1"
  assert (artProgressOf "weiyuan_sword" player == Just 12) "the second lesson did not add proficiency"
  assert (artProgressOf "basic_sword" player == Just 6) "the lesson did not share proficiency with the foundation"
  assert (enabledArtIn Sword "nameless_trial_sword" player) "learning must not replace the enabled sword art"
  assert ((player ^. playerPotential) == 18) "teacher learning did not consume potential"
  assert ((player ^. playerCharacter . charJing) == 96) "teacher learning did not consume jing"

  expectError "research before research_from" "research_too_early" learned (playerResearchArt "tester" "weiyuan_sword")

  let atTeacherCap = learned & setTesterArt Sword "weiyuan_sword" 5 0 & players . ix "tester" . playerCombatExp .~ 1000
  expectError "learn past teacher cap" "teacher_art_level_cap" atTeacherCap (playerLearnArt "tester" testCombatNpcId "weiyuan_sword" 1)

  let fullBar = learned & setTesterArt Sword "weiyuan_sword" 3 59
  expectError "learn without combat exp" "combat_exp_too_low" fullBar (playerLearnArt "tester" testCombatNpcId "weiyuan_sword" 1)
  (_, filled) <- runOk "fill the bar without combat exp" (learned & setTesterArt Sword "weiyuan_sword" 3 50) (playerLearnArt "tester" testCombatNpcId "weiyuan_sword" 1)
  filledPlayer <- requirePlayer filled
  assert (knowsArtAt "weiyuan_sword" 3 filledPlayer && artProgressOf "weiyuan_sword" filledPlayer == Just 59) "missing combat exp should hold proficiency one short of the next level"

  let caughtUp =
        learned
          & setTesterArt Sword "weiyuan_sword" 3 0
          & setTesterArt Foundation "basic_sword" 3 0
          & players . ix "tester" . playerCombatExp .~ 1000
  (_, intoFoundation) <- runOk "practise at the foundation's level" caughtUp (practiceStep "tester" "weiyuan_sword")
  foundationPlayer <- requirePlayer intoFoundation
  assert (artProgressOf "weiyuan_sword" foundationPlayer == Just 0) "practice raised an art past its foundation"
  assert (artProgressOf "basic_sword" foundationPlayer == Just 4) "practice at the bottleneck did not go to the foundation"
  assert ((foundationPlayer ^. playerCharacter . charHP) < (player ^. playerCharacter . charHP)) "sword practice did not cost hp"

  let researchable = learned & setTesterArt Sword "weiyuan_sword" 10 0 & players . ix "tester" . playerCombatExp .~ 2000
  (_, researched) <- runOk "research learned art" researchable (playerResearchArt "tester" "weiyuan_sword")
  researchedPlayer <- requirePlayer researched
  assert (artProgressOf "weiyuan_sword" researchedPlayer == Just 20) "research did not add proficiency"
  assert ((researchedPlayer ^. playerPotential) == 17) "research did not consume potential"
  assert ((researchedPlayer ^. playerCharacter . charJing) == 66) "research did not consume jing"

  let withManual = researchable & players . ix "tester" . playerInventory . at "weiyuan_sword_manual" ?~ 1
  expectError "study past the manual's band" "book_exhausted" withManual (playerStudyItem "tester" "weiyuan_sword_manual")
  (_, studied) <- runOk "study within the band" (withManual & setTesterArt Sword "weiyuan_sword" 4 0) (playerStudyItem "tester" "weiyuan_sword_manual")
  studiedPlayer <- requirePlayer studied
  assert (artProgressOf "weiyuan_sword" studiedPlayer == Just 14) "study did not add the manual's proficiency"

  (_, meditated) <- runOk "meditate for max qi" learned (playerMeditate "tester" 40)
  meditatedPlayer <- requirePlayer meditated
  assert ((meditatedPlayer ^. playerCharacter . charQi) == 60) "meditation did not consume qi"
  assert ((meditatedPlayer ^. playerCharacter . charMaxQi) == 102) "meditation did not raise max qi"
  assert ((meditatedPlayer ^. playerCharacter . charJing) == 91) "meditation did not consume jing"
  let atQiCap = learned & players . ix "tester" . playerCharacter . charMaxQi .~ 110
  expectError "meditate at the internal cap" "max_qi_at_cap" atQiCap (playerMeditate "tester" 40)

testBattleAndQuestGrowthRewards :: IO ()
testBattleAndQuestGrowthRewards = do
  gs <- newTestPlayerState
  let winBattle state = do
        (_, inBattle) <- startTrainingBattle state
        let defeatedEnemy = inBattle & battles . ix "tester" . battleEnemyState . battleChar . charHP .~ 0
        runOk "win battle" defeatedEnemy (updateBattle 0 "tester")
  (_, won) <- winBattle gs
  wonPlayer <- requirePlayer won
  -- Rank 1 against rank 1: 3 combat exp and 1 potential.
  assert ((wonPlayer ^. playerCombatExp) == 3) "equal-rank win did not grant base combat exp"
  assert ((wonPlayer ^. playerPotential) == 21) "equal-rank win did not grant potential"

  let outgrown = gs & players . ix "tester" . playerCombatExp .~ 300
  (outgrownResponses, outgrownWin) <- winBattle outgrown
  outgrownPlayer <- requirePlayer outgrownWin
  assert ((outgrownPlayer ^. playerCombatExp) == 300) "training dummy kept paying past its ceiling"
  assert (any (\case SystemMsg (SystemMessage "battle_reward_none" _) -> True; _ -> False) (map snd outgrownResponses)) "no-reward win was not explained"

  let strongPlayer =
        gs
          & players . ix "tester" . playerCharacter . charArt . ix Foundation %~ setArtLevel "basic_sword" 20
  (_, weakWin) <- winBattle strongPlayer
  weakWinPlayer <- requirePlayer weakWin
  assert ((weakWinPlayer ^. playerCombatExp) == 0) "beating a far weaker enemy paid full reward"

  (_, questDone) <- runOk "complete quest" gs (grantQuestReward "tester" "journey_luoyang")
  questPlayer <- requirePlayer questDone
  assert ((questPlayer ^. playerCombatExp) == 40) "quest did not grant combat exp"
  assert ((questPlayer ^. playerPotential) == 45) "quest did not grant potential"

  let nearCap = gs & players . ix "tester" . playerPotential .~ 195
  (capResponses, capped) <- runOk "quest at potential cap" nearCap (grantQuestReward "tester" "journey_luoyang")
  cappedPlayer <- requirePlayer capped
  -- Cap after the quest: 200 + 40 / 10 = 204.
  assert ((cappedPlayer ^. playerPotential) == 204) "potential went past the soft cap"
  assert (any (\case SystemMsg (SystemMessage "potential_full" _) -> True; _ -> False) (map snd capResponses)) "potential cap was not reported"

testTrainingQueue :: IO ()
testTrainingQueue = do
  assert (eitherDecode "{\"practice\":\"weiyuan_sword\"}" == Right (Practice "weiyuan_sword" 1)) "bare practice did not decode"
  assert (eitherDecode "{\"practice\":{\"art\":\"weiyuan_sword\",\"times\":10}}" == Right (Practice "weiyuan_sword" 10)) "timed practice did not decode"
  assert (eitherDecode "{\"meditate\":40}" == Right (Meditate 40 1)) "bare meditate did not decode"
  assert (eitherDecode "{\"study\":{\"item\":\"weiyuan_sword_manual\",\"times\":3}}" == Right (Study "weiyuan_sword_manual" 3)) "timed study did not decode"
  gs <- newTestPlayerState
  let ready =
        gs
          & players . ix "tester" . playerCombatExp .~ 1000
          & setTesterArt Foundation "basic_sword" 10 0
  (_, started) <- runOk "queue practice" ready (processPlayerAction "tester" (Practice "nameless_trial_sword" 5))
  startedPlayer <- requirePlayer started
  assert (artProgressOf "nameless_trial_sword" startedPlayer == Just 5) "the first queued step did not run at once"
  expectError "practice while busy" "player_busy" started (processPlayerAction "tester" (Practice "nameless_trial_sword" 1))

  (_, halfway) <- runOk "tick two steps" started (tickTraining practiceBusySeconds >> tickTraining practiceBusySeconds)
  halfwayPlayer <- requirePlayer halfway
  assert (artProgressOf "nameless_trial_sword" halfwayPlayer == Just 15) "ticks did not run the queued steps"

  (finishResponses, finished) <- runOk "finish the queue" halfway (replicateM_ 3 (tickTraining practiceBusySeconds))
  finishedPlayer <- requirePlayer finished
  assert (artProgressOf "nameless_trial_sword" finishedPlayer == Just 25) "the queue ran more or fewer than five steps"
  assert (isNothing $ finished ^? playerRuntime . ix "tester" . runtimeBusy . _Just) "the queue did not end"
  assert (any (\case SystemMsg (SystemMessage "training_finished" params) -> M.lookup "completed" params == Just "5"; _ -> False) (map snd finishResponses)) "finishing did not report five steps"

  -- Jing for exactly two steps: the third fails, the first two stay.
  let tired = ready & players . ix "tester" . playerCharacter . charJing .~ 12
  (_, tiredStart) <- runOk "queue while tired" tired (processPlayerAction "tester" (Practice "nameless_trial_sword" 5))
  (stopResponses, stopped) <- runOk "run out of jing" tiredStart (replicateM_ 3 (tickTraining practiceBusySeconds))
  stoppedPlayer <- requirePlayer stopped
  assert (artProgressOf "nameless_trial_sword" stoppedPlayer == Just 10) "a failed step undid the completed ones"
  assert (any (\case SystemMsg (SystemMessage "training_finished" params) -> M.lookup "reason" params == Just "not_enough_jing"; _ -> False) (map snd stopResponses)) "the stop reason was not reported"

  (_, walkedOff) <- runOk "walk away mid-queue" (withStarterExit East (RoomRef "bianshui_road" (0, 0)) started) (processPlayerAction "tester" (Go East))
  assert (isNothing $ walkedOff ^? playerRuntime . ix "tester" . runtimeBusy . _Just) "moving did not halt training"

expectError :: String -> T.Text -> GameState -> GameStateT a -> IO ()
expectError label expectedCode gs action = do
  result <- runGameState gs action
  case result of
    Left (StructuredException (ErrorSummary code _)) ->
      assert (code == expectedCode) $ label <> ": expected " <> T.unpack expectedCode <> ", got " <> T.unpack code
    Left err -> fail $ label <> ": expected " <> T.unpack expectedCode <> ", got " <> show err
    Right _ -> fail $ label <> ": expected " <> T.unpack expectedCode <> ", but it succeeded"

-- | Drop any queued training so the next command is not refused as busy.
idle :: GameState -> GameState
idle = playerRuntime . ix "tester" . runtimeBusy .~ Nothing

restTester :: GameStateT ()
restTester = do
  players . ix "tester" . playerCharacter . charJing .= 999
  players . ix "tester" . playerCharacter . charHP .= 999
  players . ix "tester" . playerCharacter . charQi .= 999

setArtLevel :: ArtId -> Int -> [ArtEntity] -> [ArtEntity]
setArtLevel targetArtId level =
  map (\known -> if known ^. artDef == targetArtId then known & artLevel .~ level & artProgress .~ 0 else known)

setTesterArt :: ArtType -> ArtId -> Int -> Int -> GameState -> GameState
setTesterArt artType' targetArtId level progress =
  players . ix "tester" . playerCharacter . charArt . ix artType' %~ map setOne
  where
    setOne known
      | known ^. artDef == targetArtId = known & artLevel .~ level & artProgress .~ progress
      | otherwise = known

artProgressOf :: ArtId -> Player -> Maybe Int
artProgressOf targetArtId player =
  case [known ^. artProgress | knownArts <- M.elems $ player ^. playerCharacter . charArt, known <- knownArts, known ^. artDef == targetArtId] of
    [] -> Nothing
    progresses -> Just $ maximum progresses

testTeacherRequiresStoryFlag :: IO ()
testTeacherRequiresStoryFlag = do
  gs <- newTestPlayerState
  let gated =
        withCombatNpcInStarterRoom gs
          & world . chars . ix testCombatNpcId . charTeachRequires ?~ TeachRequirement "test.trusted" "门外人不教。"
  refused <- runGameState gated (playerLearnArt "tester" testCombatNpcId "weiyuan_sword" 1)
  case refused of
    Left (StructuredException (ErrorSummary code params)) -> do
      assert (code == "teacher_refuses") "gated teacher used the wrong error code"
      assert (M.lookup "reason" params == Just "门外人不教。") "gated teacher did not pass the refusal line"
    Left err -> fail $ "expected teacher refusal, got: " <> show err
    Right _ -> fail "gated teacher taught a player without the required flag"
  let trusted = gated & stories . ix "tester" . storyFlags %~ S.insert "test.trusted"
  (_, learned) <- runOk "learn from trusting teacher" trusted (playerLearnArt "tester" testCombatNpcId "weiyuan_sword" 1)
  case M.lookup "tester" (learned ^. players) of
    Nothing -> fail "tester missing after gated learning"
    Just player -> assert (knowsArtAt "weiyuan_sword" 1 player) "trusted player could not learn from the gated teacher"

testStoryConditionsAndRoomVariants :: IO ()
testStoryConditionsAndRoomVariants = do
  gs <- newTestPlayerState
  (_, holding) <- runOk "check item and map conditions" gs $ do
    lacking <- storyConditionMet "tester" (LacksItem "soaked_route_note")
    inTemple <- storyConditionMet "tester" (InMap "weiyuan_road")
    elsewhere <- storyConditionMet "tester" (InMap "kaifeng_city")
    unless (lacking && inTemple && not elsewhere) $ throwError $ OtherException "conditions misjudged a fresh player"
    addInventoryItem "tester" "soaked_route_note" 1
  (_, checked) <- runOk "check item condition after pickup" holding $ do
    holds <- storyConditionMet "tester" (HasItem "soaked_route_note")
    unless holds $ throwError $ OtherException "has_item missed a held item"
  let variant =
        checked
          & world . maps . ix "weiyuan_road" . mapRooms . ix (3, 3) . roomDescVariants .~ [("test.later", "庙里只剩冷灰。")]
  (plainResponses, _) <- runOk "view room without flag" variant (playerView "tester")
  assert (any (\case ViewMsg _ desc _ _ -> desc /= "庙里只剩冷灰。"; _ -> False) (map snd plainResponses)) "room variant shown without its flag"
  let flagged = variant & stories . ix "tester" . storyFlags %~ S.insert "test.later"
  (flaggedResponses, _) <- runOk "view room with flag" flagged (playerView "tester")
  assert (any (\case ViewMsg _ desc _ _ -> desc == "庙里只剩冷灰。"; _ -> False) (map snd flaggedResponses)) "room variant not shown with its flag"

testJingRequirementFailure :: IO ()
testJingRequirementFailure = do
  gs <- newTestPlayerState
  let exhausted =
        gs
          & players . ix "tester" . playerCharacter . charJing .~ 0
  result <- runGameState (withCombatNpcInStarterRoom exhausted) (playerLearnArt "tester" "weiyuan_training_dummy" "weiyuan_sword" 1)
  case result of
    Left (StructuredException (ErrorSummary code params)) -> do
      assert (code == "not_enough_jing") "jing failure used the wrong error code"
      assert (M.lookup "required" params == Just "12") "jing failure did not include the required amount"
      assert (M.lookup "current" params == Just "0") "jing failure did not include the current amount"
    Left err -> fail $ "expected structured jing error, got: " <> show err
    Right _ -> fail "learning succeeded without enough jing"

testJingTickRecovery :: IO ()
testJingTickRecovery = do
  gs <- newTestPlayerState
  let tired =
        gs
          & players . ix "tester" . playerCharacter . charJing .~ 10
  (_, recovered) <- runOk "recover jing tick" tired (onGameTick 2)
  case M.lookup "tester" (recovered ^. players) of
    Nothing -> fail "tester missing after jing recovery"
    Just player -> do
      assert ((player ^. playerCharacter . charJing) > 10) "jing did not recover on tick"
      assert ((player ^. playerCharacter . charJing) <= (deriveStats player ^. dsMaxJing)) "jing recovery exceeded derived max"

testOutOfCombatRecovery :: IO ()
testOutOfCombatRecovery = do
  gs <- newTestPlayerState
  let hurt =
        gs
          & players . ix "tester" . playerCharacter . charHP .~ 1
          & players . ix "tester" . playerCharacter . charQi .~ 0
  (_, outside) <- runOk "recover outside" hurt (onGameTick 10)
  outsidePlayer <- requirePlayer outside
  let outsideHp = outsidePlayer ^. playerCharacter . charHP
      outsideQi = outsidePlayer ^. playerCharacter . charQi
  assert (outsideHp > 1) "hp did not recover out of combat"
  assert (outsideQi > 0) "qi did not recover out of combat"

  (_, carried) <- runOk "recover in small steps" hurt (replicateM_ 10 (onGameTick 1))
  carriedPlayer <- requirePlayer carried
  assert ((carriedPlayer ^. playerCharacter . charHP) == outsideHp) "one-second ticks lost the fractional recovery"

  (_, atInn) <- runOk "move to inn" hurt (movePlayerToRoom "tester" "kaifeng_city" (-1, 1))
  (_, rested) <- runOk "recover at inn" atInn (onGameTick 10)
  restedPlayer <- requirePlayer rested
  assert ((restedPlayer ^. playerCharacter . charHP) > outsideHp) "resting at the inn did not speed up recovery"

  (_, full) <- runOk "recover to full" hurt (onGameTick 100000)
  fullPlayer <- requirePlayer full
  let derived = deriveStats fullPlayer
  assert ((fullPlayer ^. playerCharacter . charHP) == derived ^. dsMaxHp) "hp recovery did not stop at max"
  assert ((fullPlayer ^. playerCharacter . charQi) == derived ^. dsMaxQi) "qi recovery did not stop at max"

testDefeatLeavesPlayerInjured :: IO ()
testDefeatLeavesPlayerInjured = do
  gs <- newTestPlayerState
  (_, inBattle) <- startTrainingBattle gs
  let defeated = inBattle & battles . ix "tester" . battleState . battleChar . charHP .~ 0
  (_, settled) <- runOk "settle defeat" defeated (updateBattle 0 "tester")
  injuredAttack <- runGameState settled (playerAttack "tester" testCombatNpcId)
  case injuredAttack of
    Left (StructuredException (ErrorSummary code _)) -> assert (code == "player_injured") "injured attack used the wrong error code"
    Left err -> fail $ "expected injured refusal, got: " <> show err
    Right _ -> fail "injured player started a battle"

  (_, injuredTick) <- runOk "injured recovery" settled (onGameTick 10)
  let healthy = settled & playerRuntime . ix "tester" . runtimeInjuredRemaining .~ 0
  (_, healthyTick) <- runOk "healthy recovery" healthy (onGameTick 10)
  injuredPlayer <- requirePlayer injuredTick
  healthyPlayer <- requirePlayer healthyTick
  assert ((injuredPlayer ^. playerCharacter . charHP) < (healthyPlayer ^. playerCharacter . charHP)) "injury did not slow hp recovery"

  (_, recovered) <- runOk "injury wears off" settled (onGameTick 301)
  (_, _) <- runOk "attack after injury" recovered (playerAttack "tester" testCombatNpcId)
  pure ()

requirePlayer :: GameState -> IO Player
requirePlayer gs =
  case M.lookup "tester" (gs ^. players) of
    Nothing -> fail "tester missing"
    Just player -> pure player

testLearningRequirementFailure :: IO ()
testLearningRequirementFailure = do
  gs <- newTestPlayerState
  let targetArtId = "weiyuan_sword"
      expectedArtName = gs ^. world . martialArts . ix targetArtId . artName
  let gated =
        gs
          & world . martialArts . ix targetArtId . artRequires .~ [ArtRequirement "basic_sword" 99]
  result <- runGameState gated (grantArt "tester" targetArtId 1)
  case result of
    Left (StructuredException (ErrorSummary code params)) -> do
      assert (code == "cannot_learn_art") "learning failure used the wrong error code"
      assert (M.lookup "art" params == Just expectedArtName) "learning failure did not include the art name"
      assert (maybe False ("基础剑法" `T.isInfixOf`) (M.lookup "requirements" params)) "learning failure did not include missing foundation"
    Left err -> fail $ "expected structured learning error, got: " <> show err
    Right _ -> fail "learning succeeded despite unmet foundation requirement"

testArtsQuery :: IO ()
testArtsQuery = do
  gs <- newTestPlayerState
  (responses, _) <- runOk "query arts" gs (playerArts "tester")
  case [arts | (_, ArtsMsg arts) <- responses] of
    [] -> fail "arts query did not send ArtsMsg"
    arts : _ -> do
      assert (any (\art -> artSummaryId art == "basic_sword" && artSummaryIsFoundation art) arts) "arts query omitted basic_sword foundation"
      assert (any (\art -> artSummaryId art == "nameless_trial_fist" && artSummaryType art == "fist") arts) "arts query omitted starter fist art"

testWeiyuanChapterFlow :: IO ()
testWeiyuanChapterFlow = do
  gs <- newTestPlayerState
  (warningResponses, warned) <- runOk "hear old escort warning" gs (playerTalk "tester" "wounded_escort")
  assert (questStageOf "weiyuan_bloody_case" warned == Just "intruder") "weiyuan quest did not enter intruder stage"
  assert (snd (head warningResponses) == StorySequenceMsg True) "story sequence did not lock output before the opening dialogue"
  assert (snd (last warningResponses) == StorySequenceMsg False) "story sequence did not unlock output after the opening dialogue"
  kickIndex <- requireResponseIndex "temple door narration" (== StoryMsg "旁白" "话音未落，庙门外响起急促脚步。半扇破门被人一脚踹开，雨水和冷风一起灌进殿里。") warningResponses
  revealIndex <- requireResponseIndex "black-clad room refresh" (\case ViewMsg _ _ characters _ -> any ((== "temple_black_clad") . roomCharacterSummaryId) characters; _ -> False) warningResponses
  threatIndex <- requireResponseIndex "black-clad threat" (== StoryMsg "黑衣人" "威远的人果然在这里。今夜这座庙里，不该再有活口。") warningResponses
  assert (kickIndex < revealIndex && revealIndex < threatIndex) "black-clad NPC was not revealed between the door narration and threat"

  directAttack <- runGameState warned (playerAttack "tester" "temple_black_clad")
  case directAttack of
    Left (UnableToInteract _ Attacking) -> pure ()
    Left err -> fail $ "expected direct story NPC attack to be blocked, got: " <> show err
    Right _ -> fail "story NPC exposed a direct attack path"

  (battleStartResponses, inBattle) <- runOk "confront temple attacker" warned (playerTalk "tester" "temple_black_clad")
  assert (questStageOf "weiyuan_bloody_case" inBattle == Just "duel") "weiyuan quest did not enter duel stage"
  assert (S.member "tester" $ inBattle ^. isolatedBattles) "story battle was not marked isolated"
  assert (maybe False ((== CharAlive) . view charStatus) $ M.lookup "temple_black_clad" (inBattle ^. world . chars)) "story battle locked the global NPC"
  startedBattle <- getBattle inBattle
  assert (startedBattle ^. battleActionLockRemaining > 0) "story battle advanced while its opening dialogue was still queued"
  battleSnapshotIndex <- requireResponseIndex "visible story battle snapshot" (\case BattleStateMsg snapshot -> battleSnapshotActionLockRemaining snapshot == 0; _ -> False) battleStartResponses
  attackIndex <- requireResponseIndex "story battle attack message" (\case AttackMsg _ _ -> True; _ -> False) battleStartResponses
  assert (attackIndex < battleSnapshotIndex) "story battle snapshot arrived before its attack message"

  let defeated = inBattle & battles . ix "tester" . battleEnemyState . battleChar . charHP .~ 0
  (settlementResponses, afterFight) <- runOk "settle temple fight" defeated (updateBattle 0 "tester")
  assert (questStageOf "weiyuan_bloody_case" afterFight == Just "escort_dying") "weiyuan quest did not advance after the fight"
  assert (not $ S.member "tester" $ afterFight ^. isolatedBattles) "isolated battle marker was not cleared"
  assert (maybe False ((== CharAlive) . view charStatus) $ M.lookup "temple_black_clad" (afterFight ^. world . chars)) "isolated story fight changed the global NPC"
  settlementIndex <- requireResponseIndex "combat settlement" (\case CombatSettlementMsg _ _ _ -> True; _ -> False) settlementResponses
  aftermathDelayIndex <- requireResponseIndex "post-combat pause" (== StoryDelayMsg 1800) settlementResponses
  collapseIndex <- requireResponseIndex "post-combat collapse" (== StoryMsg "旁白" "黑衣人倒在门边。老镖师扶着断柱站起，才迈出半步，便又重重坐了下去。") settlementResponses
  growthRewardIndex <- requireResponseIndex "battle growth reward" (\case RewardMsg rewards -> any ((== "combat_exp") . rewardSummaryKind) rewards; _ -> False) settlementResponses
  assert (settlementIndex < aftermathDelayIndex && aftermathDelayIndex < collapseIndex && collapseIndex < growthRewardIndex) "battle aftermath was not paced after settlement or reward was shown too early"

  (roadResponses, onRoad) <- runOk "hear old escort last request" afterFight (playerTalk "tester" "wounded_escort")
  assert (questStageOf "weiyuan_bloody_case" onRoad == Just "escort_road") "weiyuan quest did not enter escort road stage"
  case M.lookup "tester" (onRoad ^. players) of
    Nothing -> fail "tester missing on escort road"
    Just player -> do
      assert ((player ^. playerPosition) == ("bianshui_road", (0, 0))) "old escort did not send the player to the escort road"
      assert ((player ^. playerMoney) >= 30) "sourced travel money was not granted"
  transitionIndex <- requireResponseIndex "temple exit transition" (== StoryTransitionMsg "你与少年冒雨离开破庙，踏上汴水官道。" 1800) roadResponses
  moveIndex <- requireResponseIndex "escort road move" (== MoveMsg "官道口") roadResponses
  roadDialogueIndex <- requireResponseIndex "escort road follow-up" (== StoryMsg "灰衣少年" "沿汴水往北先到南渡，过州桥才是城门。追兵未必只有一个，我们别在路上停。") roadResponses
  travelMoneyIndex <- requireResponseIndex "deferred travel money" (\case RewardMsg rewards -> any ((== "money") . rewardSummaryKind) rewards; _ -> False) roadResponses
  assert (transitionIndex < moveIndex && moveIndex < roadDialogueIndex && roadDialogueIndex < travelMoneyIndex) "transition, move, follow-up dialogue, and reward were not emitted in narrative order"

  (_, atFerry) <- runOk "escort young survivor into Kaifeng" onRoad (playerMove "tester" North)
  assert (questStageOf "weiyuan_bloody_case" atFerry == Just "branch_gate") "entering Kaifeng did not advance the escort"
  (_, atGate) <- runOk "approach Weiyuan branch" atFerry (playerMove "tester" East)
  (hallResponses, inHall) <- runOk "enter Weiyuan branch hall" atGate (playerMove "tester" East)
  assert (questStageOf "weiyuan_bloody_case" inHall == Just "inner_court") "the youth did not run into the inner court"
  rushIndex <- requireResponseIndex "youth rushes inside" (\case StoryMsg "旁白" text -> "冲进了通往内院" `T.isInfixOf` text; _ -> False) hallResponses
  hideIndex <- requireResponseIndex "young escort hide refresh" (\case ViewMsg _ _ characters _ -> all ((/= "grey_young_escort") . roomCharacterSummaryId) characters; _ -> False) hallResponses
  manualIndex <- requireResponseIndex "manual handed over" (\case RewardMsg rewards -> any ((== Just "weiyuan_sword_manual") . rewardSummaryId) rewards; _ -> False) hallResponses
  assert (rushIndex < hideIndex && hideIndex < manualIndex) "the youth vanished or the bundle arrived before he ran inside"

  (courtResponses, inCourt) <- runOk "follow the youth into the inner court" inHall (playerMove "tester" East)
  assert (questStageOf "weiyuan_bloody_case" inCourt == Just "completed") "weiyuan quest did not complete in the inner court"
  assert (questStageOf "first_steps_kaifeng" inCourt == Just "guide") "Kaifeng settling quest did not start"
  _ <- requireResponseIndex "well inscription" (\case StoryMsg _ text -> "别找我" `T.isInfixOf` text; _ -> False) courtResponses
  case M.lookup "tester" (inCourt ^. stories) of
    Nothing -> fail "tester story state missing after Weiyuan separation"
    Just storyState -> do
      assert (S.member "weiyuan.youth_separated" $ storyState ^. storyFlags) "young survivor separation flag was not set"
      assert (S.member "grey_young_escort" $ storyState ^. storyHiddenNpcs) "young survivor was not hidden after separation"
  case M.lookup "tester" (inCourt ^. players) of
    Nothing -> fail "tester missing after Weiyuan completion"
    Just player -> do
      assert ((player ^. playerInventory . at "soaked_route_note") == Just 1) "route note was not retained"
      assert ((player ^. playerInventory . at "weiyuan_sword_manual") == Just 1) "Weiyuan manual was not retained"
      assert ((player ^. playerPosition) == ("kaifeng_city", (-1, -3))) "player did not slip out to the willow bank"

testKaifengJianghuFlow :: IO ()
testKaifengJianghuFlow = do
  gs <- newTestPlayerState
  let settled =
        gs
          & stories . ix "tester" . storyQuestStages . at "weiyuan_bloody_case" ?~ "completed"
          & stories . ix "tester" . storyQuestStages . at "first_steps_kaifeng" ?~ "completed"
  (_, atDock) <- runOk "move to willow bank" settled (movePlayerToRoom "tester" "kaifeng_city" (-1, -3))
  (_, recognised) <- runOk "du san recognises the player" atDock (playerTalk "tester" "caoban_du_san")
  assert (hasFlag "caoban.saw_you" recognised) "du san did not remember the back door"
  (_, accepted) <- runOk "accept dock job" recognised (playerTalk "tester" "caoban_du_san")
  assert (questStageOf "caoban_dock_rules" accepted == Just "accepted") "dock job did not start"
  (_, atShed) <- runOk "move to boat shed" accepted (movePlayerToRoom "tester" "kaifeng_city" (1, -2))
  (_, fighting) <- runOk "confront salt gang thug" atShed (playerTalk "tester" "salt_gang_thug")
  let beaten = fighting & battles . ix "tester" . battleEnemyState . battleChar . charHP .~ 0
  (_, drivenOff) <- runOk "settle dock fight" beaten (updateBattle 0 "tester")
  assert (questStageOf "caoban_dock_rules" drivenOff == Just "report") "dock fight did not advance to report"
  (_, backAtDock) <- runOk "return to du san" drivenOff (movePlayerToRoom "tester" "kaifeng_city" (-1, -3))
  (_, named) <- runOk "report to du san" backAtDock (playerTalk "tester" "caoban_du_san")
  assert (questStageOf "caoban_dock_rules" named == Just "completed") "dock job did not complete"
  assert (hasFlag "jianghu.name.nandu_ke" named) "player did not earn a jianghu name"
  (_, atConstable) <- runOk "move to constable office" named (movePlayerToRoom "tester" "kaifeng_city" (1, 2))
  (_, suspected) <- runOk "constable sizes up the player" atConstable (playerTalk "tester" "kaifeng_constable")
  assert (hasFlag "kaifeng.constable_suspects" suspected) "constable did not question the night at the ferry"
  (patrolResponses, patrol) <- runOk "constable offers patrol" suspected (playerTalk "tester" "kaifeng_constable")
  assert (questStageOf "north_road_patrol" patrol == Just "accepted") "constable did not offer the patrol"
  _ <- requireResponseIndex "constable notes the caoban tie" (\case StoryMsg _ text -> "南渡客" `T.isInfixOf` text; _ -> False) patrolResponses
  pure ()
  where
    hasFlag flag gs' = maybe False (S.member flag . view storyFlags) (M.lookup "tester" (gs' ^. stories))

testKaifengInterleavedQuestsAndChoices :: IO ()
testKaifengInterleavedQuestsAndChoices = do
  gs <- newTestPlayerState
  let settled =
        gs
          & stories . ix "tester" . storyQuestStages . at "weiyuan_bloody_case" ?~ "completed"
          & stories . ix "tester" . storyQuestStages . at "first_steps_kaifeng" ?~ "completed"
          & players . ix "tester" . playerCharacter . charArt . ix Foundation %~ setArtLevel "basic_fist" 6
          & players . ix "tester" . playerCharacter . charArt . ix Foundation %~ setArtLevel "basic_lightness" 6

  -- 1. Kaifeng artisan trouble (blacksmith -> pawnbroker -> banker -> physician)
  (_, atSmithy) <- runOk "move to smithy" settled (movePlayerToRoom "tester" "kaifeng_city" (3, 1))
  (_, startedArtisan) <- runOk "talk to blacksmith" atSmithy (playerTalk "tester" "kaifeng_blacksmith")
  assert (questStageOf "kaifeng_artisan_trouble" startedArtisan == Just "pawnshop") "artisan quest did not start"
  assert (itemCount "forged_iron_bracers" startedArtisan == Just 1) "blacksmith did not give iron bracers"

  (_, atPawnshop) <- runOk "move to pawnshop" startedArtisan (movePlayerToRoom "tester" "kaifeng_city" (-3, -1))
  (_, checkedBracers) <- runOk "talk to pawnbroker" atPawnshop (playerTalk "tester" "kaifeng_pawnbroker")
  assert (questStageOf "kaifeng_artisan_trouble" checkedBracers == Just "money_house") "pawnbroker did not send to money house"
  assert (itemCount "forged_iron_bracers" checkedBracers == Nothing) "pawnbroker did not take iron bracers"

  (_, atBank) <- runOk "move to money house" checkedBracers (movePlayerToRoom "tester" "kaifeng_city" (-2, -1))
  (_, redeemedMortar) <- runOk "talk to banker" atBank (playerTalk "tester" "kaifeng_banker")
  assert (questStageOf "kaifeng_artisan_trouble" redeemedMortar == Just "return_mortar") "banker did not redeem mortar"
  assert (itemCount "pawned_old_mortar" redeemedMortar == Just 1) "banker did not give old mortar"

  (_, atApothecary) <- runOk "move to apothecary" redeemedMortar (movePlayerToRoom "tester" "kaifeng_city" (2, -1))
  (_, completedArtisan) <- runOk "return mortar to physician" atApothecary (playerTalk "tester" "kaifeng_physician")
  assert (questStageOf "kaifeng_artisan_trouble" completedArtisan == Just "completed") "artisan quest did not complete"
  assert (itemCount "pawned_old_mortar" completedArtisan == Nothing) "physician did not take old mortar"
  assert (hasFlag "kaifeng.artisan_helped" completedArtisan) "artisan flag was not set"

  -- 2. Kaifeng canal shadow with two-way disposition choice (Constable vs Du San)
  (_, atWarehouse) <- runOk "move to warehouse" completedArtisan (movePlayerToRoom "tester" "kaifeng_city" (2, 1))
  (_, startedCanal) <- runOk "talk to warehouse keeper" atWarehouse (playerTalk "tester" "warehouse_keeper")
  assert (questStageOf "caoban_canal_shadow" startedCanal == Just "alley_lead") "canal shadow quest did not start"

  (_, atBackAlley) <- runOk "move to back alley" startedCanal (movePlayerToRoom "tester" "kaifeng_city" (-1, 3))
  (_, heardShallows) <- runOk "talk to beggar chen" atBackAlley (playerTalk "tester" "alley_beggar_chen")
  assert (questStageOf "caoban_canal_shadow" heardShallows == Just "reed_shallows") "beggar chen did not point to reed shallows"

  (_, atShallows) <- runOk "move to reed shallows" heardShallows (movePlayerToRoom "tester" "north_post_road" (-1, 5))
  (_, deputyFight) <- runOk "confront salt gang deputy" atShallows (playerTalk "tester" "salt_gang_deputy")
  let beatenDeputy = deputyFight & battles . ix "tester" . battleEnemyState . battleChar . charHP .~ 0
  (_, gotSealBox) <- runOk "settle deputy fight" beatenDeputy (updateBattle 0 "tester")
  assert (questStageOf "caoban_canal_shadow" gotSealBox == Just "choose_disposition") "deputy defeat did not advance to choose_disposition"
  assert (itemCount "smuggled_seal_box" gotSealBox == Just 1) "deputy defeat did not yield smuggled_seal_box"

  -- Branch A: Hand seal box to Constable Gu and study the yamen manual
  (_, atConstable) <- runOk "move to constable" gotSealBox (movePlayerToRoom "tester" "kaifeng_city" (1, 2))
  (_, reportedYamen) <- runOk "hand seal box to constable" atConstable (playerTalk "tester" "kaifeng_constable")
  assert (questStageOf "caoban_canal_shadow" reportedYamen == Just "completed") "constable did not complete canal shadow"
  assert (itemCount "smuggled_seal_box" reportedYamen == Nothing) "constable did not take smuggled_seal_box"
  assert (itemCount "yamen_bounty_manual" reportedYamen == Just 1) "constable did not grant yamen_bounty_manual"
  assert (hasFlag "jianghu.canal_reported_yamen" reportedYamen) "yamen branch flag not set"
  (_, learnedGrappling) <- runOk "use yamen manual" reportedYamen (playerUseItem "tester" "yamen_bounty_manual")
  grapplingPlayer <- requirePlayer learnedGrappling
  assert (knowsArtAt "yamen_grappling_hand" 1 grapplingPlayer) "yamen manual did not teach yamen_grappling_hand"

  -- Branch B: Hand seal box to Caoban Du San (even if caoban_dock_rules was already completed)
  let gotSealBoxWithDockDone =
        gotSealBox
          & stories . ix "tester" . storyQuestStages . at "caoban_dock_rules" ?~ "completed"
  (_, atWillowBank) <- runOk "move to willow bank" gotSealBoxWithDockDone (movePlayerToRoom "tester" "kaifeng_city" (-1, -3))
  (_, handedCaoban) <- runOk "hand seal box to du san" atWillowBank (playerTalk "tester" "caoban_du_san")
  assert (questStageOf "caoban_canal_shadow" handedCaoban == Just "completed") "du san did not complete canal shadow"
  assert (itemCount "caoban_water_manual" handedCaoban == Just 1) "du san did not grant caoban_water_manual"
  assert (hasFlag "jianghu.canal_handed_caoban" handedCaoban) "caoban branch flag not set"
  (_, learnedWaveStep) <- runOk "use caoban water manual" handedCaoban (playerUseItem "tester" "caoban_water_manual")
  wavePlayer <- requirePlayer learnedWaveStep
  assert (knowsArtAt "bianshui_wave_step" 1 wavePlayer) "caoban manual did not teach bianshui_wave_step"
  where
    hasFlag flag gs' = maybe False (S.member flag . view storyFlags) (M.lookup "tester" (gs' ^. stories))
    itemCount itemId gs' = M.lookup "tester" (gs' ^. players) >>= view (playerInventory . at itemId)

testRegionalQuestsAndWeiyuanEchoConvergence :: IO ()
testRegionalQuestsAndWeiyuanEchoConvergence = do
  gs <- newTestPlayerState
  let prepared =
        gs
          & stories . ix "tester" . storyQuestStages . at "weiyuan_bloody_case" ?~ "completed"
          & stories . ix "tester" . storyQuestStages . at "first_steps_kaifeng" ?~ "completed"
          & stories . ix "tester" . storyFlags %~ (S.insert "luoyang.name_card" . S.insert "dali.duan_trusted" . S.insert "taihu.pavilion_guest" . S.insert "weiyuan.met_envoy")
          & players . ix "tester" . playerInventory . at "weiyuan_sword_manual" ?~ 1
          & players . ix "tester" . playerInventory . at "soaked_route_note" ?~ 1
          & players . ix "tester" . playerCharacter . charArt . ix Foundation %~ (setArtLevel "basic_sword" 16 . setArtLevel "basic_lightness" 16 . setArtLevel "basic_fist" 16 . setArtLevel "basic_internal" 16)

  -- 1. Luoyang: broken manual + peony duel + Weiyuan manual clue
  (_, atBroker) <- runOk "move to Luoyang blade broker" prepared (movePlayerToRoom "tester" "luoyang_city" (-1, 2))
  (_, afterBrokerClue) <- runOk "broker spots Weiyuan manual" atBroker (playerTalk "tester" "luoyang_blade_broker")
  assert (hasFlag "weiyuan.clue_luoyang" afterBrokerClue && hasFlag "weiyuan.saw_ink_mark" afterBrokerClue) "Luoyang broker did not spot the Weiyuan manual ink mark"

  (_, atWensheng) <- runOk "move to Wensheng" afterBrokerClue (movePlayerToRoom "tester" "luoyang_city" (-1, 5))
  (_, startedManual) <- runOk "start broken manual quest" atWensheng (playerTalk "tester" "luoyang_teacher")
  assert (questStageOf "luoyang_broken_manual" startedManual == Just "investigate_weir") "broken manual quest did not start"
  (_, atWeir) <- runOk "move to weir pavilion" startedManual (movePlayerToRoom "tester" "luoyang_city" (2, 5))
  (_, forgerBattle) <- runOk "confront fake manual swordsman" atWeir (playerTalk "tester" "fake_manual_swordsman")
  let beatenForger = forgerBattle & battles . ix "tester" . battleEnemyState . battleChar . charHP .~ 0
  (_, afterForger) <- runOk "settle forger fight" beatenForger (updateBattle 0 "tester")
  assert (questStageOf "luoyang_broken_manual" afterForger == Just "baima_stele") "forger fight did not advance to baima_stele"
  (_, atStele) <- runOk "move to Baima stele pavilion" afterForger (movePlayerToRoom "tester" "luoyang_city" (-1, 7))
  (_, gotRubbing) <- runOk "talk to stone sweeper" atStele (playerTalk "tester" "baima_stone_sweeper")
  assert (itemCount "luoyang_stele_rubbing" gotRubbing == Just 1) "stone sweeper did not give rubbing"
  (_, backAtWensheng) <- runOk "return to Wensheng" gotRubbing (movePlayerToRoom "tester" "luoyang_city" (-1, 5))
  (_, completedManual) <- runOk "complete broken manual quest" backAtWensheng (playerTalk "tester" "luoyang_teacher")
  assert (questStageOf "luoyang_broken_manual" completedManual == Just "completed") "broken manual quest did not complete"
  assert (hasFlag "luoyang.wensheng_trusted" completedManual) "Wensheng trust flag was not set"

  (_, atPeony) <- runOk "move to Peony court" completedManual (movePlayerToRoom "tester" "luoyang_city" (0, 4))
  (_, startedPeony) <- runOk "start Peony duel" atPeony (playerTalk "tester" "peony_host_assistant")
  (_, atGallery) <- runOk "move to step gallery" startedPeony (movePlayerToRoom "tester" "luoyang_city" (2, 2))
  (_, stepApproved) <- runOk "talk to footwork mentor" atGallery (playerTalk "tester" "luoyang_footwork_mentor")
  (_, backAtPeony) <- runOk "return to Peony court" stepApproved (movePlayerToRoom "tester" "luoyang_city" (0, 4))
  (_, songBattle) <- runOk "duel challenger Song" backAtPeony (playerTalk "tester" "peony_challenger_song")
  let beatenSong = songBattle & battles . ix "tester" . battleEnemyState . battleChar . charHP .~ 0
  (_, afterSong) <- runOk "settle Song duel" beatenSong (updateBattle 0 "tester")
  (_, completedPeony) <- runOk "report Peony duel" afterSong (playerTalk "tester" "peony_host_assistant")
  assert (questStageOf "luoyang_peony_duel" completedPeony == Just "completed") "Peony duel did not complete"
  assert (hasFlag "luoyang.peony_duel_won" completedPeony) "Peony duel flag was not set"

  -- 2. Dali: Cangshan caravan + Chongsheng bell + Weiyuan route note clue
  (_, atDaliClerk) <- runOk "move to Dali contract clerk" completedPeony (movePlayerToRoom "tester" "dali_city" (1, 5))
  (_, afterDaliClue) <- runOk "clerk reads soaked route note" atDaliClerk (playerTalk "tester" "dali_contract_clerk")
  assert (hasFlag "weiyuan.clue_dali" afterDaliClue) "Dali clerk did not identify the route note mark"

  (_, atDaliHall) <- runOk "move to Duan hall" afterDaliClue (movePlayerToRoom "tester" "dali_city" (0, 5))
  (_, startedCangshan) <- runOk "start Cangshan quest" atDaliHall (playerTalk "tester" "dali_duan_guard_captain")
  (_, atStream) <- runOk "move to Cangshan stream" startedCangshan (movePlayerToRoom "tester" "dali_city" (-2, 2))
  (_, trackedOutlaw) <- runOk "talk to tracker" atStream (playerTalk "tester" "cangshan_tracker")
  (_, atQuarry) <- runOk "move to quarry cliff" trackedOutlaw (movePlayerToRoom "tester" "dali_city" (-2, 3))
  (_, outlawBattle) <- runOk "confront outlaw leader" atQuarry (playerTalk "tester" "cangshan_outlaw_leader")
  let beatenOutlaw = outlawBattle & battles . ix "tester" . battleEnemyState . battleChar . charHP .~ 0
  (_, afterOutlaw) <- runOk "settle outlaw fight" beatenOutlaw (updateBattle 0 "tester")
  (_, backAtDaliHall) <- runOk "return to Duan hall" afterOutlaw (movePlayerToRoom "tester" "dali_city" (0, 5))
  (_, completedCangshan) <- runOk "complete Cangshan quest" backAtDaliHall (playerTalk "tester" "dali_duan_guard_captain")
  assert (questStageOf "dali_cangshan_caravan" completedCangshan == Just "completed") "Cangshan quest did not complete"
  assert (hasFlag "dali.inner_trusted" completedCangshan) "Dali inner trust flag was not set"
  assert (itemCount "duan_temple_letter" completedCangshan == Just 1) "Duan captain did not give temple letter"

  (_, atChongsheng) <- runOk "move to Chongsheng gate" completedCangshan (movePlayerToRoom "tester" "dali_city" (0, 7))
  (_, startedBell) <- runOk "start Chongsheng bell quest" atChongsheng (playerTalk "tester" "chongsheng_monk")
  (_, atErhaiPier) <- runOk "move to Erhai pier" startedBell (movePlayerToRoom "tester" "dali_city" (2, 2))
  (_, heardBoatman) <- runOk "talk to old boatman" atErhaiPier (playerTalk "tester" "erhai_old_boatman")
  (_, atPagodaGate) <- runOk "return to Chongsheng gate" heardBoatman (movePlayerToRoom "tester" "dali_city" (0, 7))
  (_, inPagoda) <- runOk "enter Three Pagodas courtyard" atPagodaGate (playerMove "tester" North)
  assert (questStageOf "dali_chongsheng_bell" inPagoda == Just "report_monk") "entering pagoda courtyard did not advance bell quest"
  (_, backAtMonk) <- runOk "step south to monk" inPagoda (playerMove "tester" South)
  (_, completedBell) <- runOk "complete Chongsheng bell quest" backAtMonk (playerTalk "tester" "chongsheng_monk")
  assert (questStageOf "dali_chongsheng_bell" completedBell == Just "completed") "Chongsheng bell quest did not complete"
  assert (hasFlag "dali.chongsheng_vow" completedBell) "Chongsheng vow flag was not set"

  -- 3. Taihu: water debt + wounded traveler clue
  (_, atPulseRoom) <- runOk "move to Taihu pulse room" completedBell (movePlayerToRoom "tester" "taihu_water_pavilion" (-1, 3))
  (_, afterTaihuClue) <- runOk "talk to wounded traveler" atPulseRoom (playerTalk "tester" "taihu_wounded_traveler")
  assert (hasFlag "weiyuan.clue_taihu" afterTaihuClue) "Taihu wounded traveler did not share Weiyuan clue"

  (_, atTaihuHall) <- runOk "move to Taihu hall" afterTaihuClue (movePlayerToRoom "tester" "taihu_water_pavilion" (0, 4))
  (_, startedDebt) <- runOk "start Taihu water debt" atTaihuHall (playerTalk "tester" "taihu_senior")
  (_, atArchivist) <- runOk "move to formula room" startedDebt (movePlayerToRoom "tester" "taihu_water_pavilion" (1, 4))
  (_, gotPrescription) <- runOk "get split prescription" atArchivist (playerTalk "tester" "taihu_archivist")
  (_, atJetty) <- runOk "move to mist jetty" gotPrescription (movePlayerToRoom "tester" "taihu_water_pavilion" (1, 5))
  (_, visitedEstate) <- runOk "talk to estate steward" atJetty (playerTalk "tester" "estate_steward_lu")
  (_, atCoving) <- runOk "move to reed coving" visitedEstate (movePlayerToRoom "tester" "taihu_water_pavilion" (-1, 5))
  (_, bossBattle) <- runOk "confront water fort second boss" atCoving (playerTalk "tester" "water_fort_second_boss")
  let beatenBoss = bossBattle & battles . ix "tester" . battleEnemyState . battleChar . charHP .~ 0
  (_, afterBoss) <- runOk "settle water fort boss fight" beatenBoss (updateBattle 0 "tester")
  (_, backAtTaihuHall) <- runOk "return to Taihu hall" afterBoss (movePlayerToRoom "tester" "taihu_water_pavilion" (0, 4))
  (_, completedDebt) <- runOk "complete Taihu water debt" backAtTaihuHall (playerTalk "tester" "taihu_senior")
  assert (questStageOf "taihu_water_debt" completedDebt == Just "completed") "Taihu water debt did not complete"
  assert (hasFlag "taihu.inner_guest" completedDebt) "Taihu inner guest flag was not set"

  -- 4. Convergence: Weiyuan First Echo at the abandoned military shrine on North Post Road
  (_, atFork) <- runOk "move to north road fork" completedDebt (movePlayerToRoom "tester" "north_post_road" (0, 3))
  (_, atShrine) <- runOk "enter abandoned shrine" atFork (playerMove "tester" North)
  assert (questStageOf "weiyuan_first_echo" atShrine == Just "ambush") "entering abandoned shrine did not trigger Weiyuan ambush"
  (_, stalkerBattle) <- runOk "confront ink mark stalker" atShrine (playerTalk "tester" "ink_mark_stalker")
  let beatenStalker = stalkerBattle & battles . ix "tester" . battleEnemyState . battleChar . charHP .~ 0
  (_, afterStalker) <- runOk "settle stalker fight" beatenStalker (updateBattle 0 "tester")
  assert (questStageOf "weiyuan_first_echo" afterStalker == Just "choose_report") "stalker defeat did not advance to choose_report"

  (_, atEnvoy) <- runOk "move to Weiyuan envoy" afterStalker (movePlayerToRoom "tester" "kaifeng_city" (1, -3))
  (_, reportedEnvoy) <- runOk "report shrine echo to envoy" atEnvoy (playerTalk "tester" "weiyuan_envoy")
  assert (questStageOf "weiyuan_first_echo" reportedEnvoy == Just "completed") "reporting to envoy did not complete weiyuan_first_echo"
  assert (hasFlag "weiyuan.echo_reported_envoy" reportedEnvoy && hasFlag "weiyuan.echo_resolved" reportedEnvoy) "envoy report flags were not set"

  -- Storyteller in Kaifeng reacts to the resolved shrine echo
  (_, atTeaHouse) <- runOk "move to tea house" reportedEnvoy (movePlayerToRoom "tester" "kaifeng_city" (-2, 1))
  (storyResponses, afterStory) <- runOk "talk to storyteller" atTeaHouse (playerTalk "tester" "tea_storyteller")
  assert (hasFlag "kaifeng.heard_shrine_echo" afterStory) "storyteller did not recount the shrine echo"
  _ <- requireResponseIndex "storyteller mentions abandoned shrine" (\case StoryMsg _ text -> "废军祠" `T.isInfixOf` text; _ -> False) storyResponses
  pure ()
  where
    hasFlag flag gs' = maybe False (S.member flag . view storyFlags) (M.lookup "tester" (gs' ^. stories))
    itemCount itemId gs' = M.lookup "tester" (gs' ^. players) >>= view (playerInventory . at itemId)

testStoryBattlesArePlayerIsolated :: IO ()
testStoryBattlesArePlayerIsolated = do
  gs <- newTestPlayerState
  (_, twoPlayers) <- runOk "create second story player" gs (createDefaultPlayer "tester2" "resources/scripts/default_player.yaml")
  (_, firstWarned) <- runOk "warn first player" twoPlayers (playerTalk "tester" "wounded_escort")
  (_, bothWarned) <- runOk "warn second player" firstWarned (playerTalk "tester2" "wounded_escort")
  (_, firstBattle) <- runOk "start first isolated story battle" bothWarned (playerTalk "tester" "temple_black_clad")
  (_, bothBattles) <- runOk "start second isolated story battle" firstBattle (playerTalk "tester2" "temple_black_clad")
  assert (M.member "tester" $ bothBattles ^. battles) "first isolated story battle disappeared"
  assert (M.member "tester2" $ bothBattles ^. battles) "second isolated story battle did not start"
  assert (maybe False ((== CharAlive) . view charStatus) $ M.lookup "temple_black_clad" (bothBattles ^. world . chars)) "concurrent story battles locked the shared NPC"

testKaifengSettlingAndTravelFlow :: IO ()
testKaifengSettlingAndTravelFlow = do
  gs <- newTestPlayerState
  let ready =
        gs
          & stories . ix "tester" . storyQuestStages . at "weiyuan_bloody_case" ?~ "completed"
          & stories . ix "tester" . storyQuestStages . at "first_steps_kaifeng" ?~ "guide"
  (_, atSouthGate) <- runOk "move to Kaifeng south gate" ready (movePlayerToRoom "tester" "kaifeng_city" (0, -1))
  (_, seekingInn) <- runOk "ask guide for lodging" atSouthGate (playerTalk "tester" "kaifeng_guide")
  assert (questStageOf "first_steps_kaifeng" seekingInn == Just "inn") "guide did not send the player to the inn"

  (_, atInn) <- runOk "move to Fanlou inn" seekingInn (movePlayerToRoom "tester" "kaifeng_city" (-1, 1))
  (_, lodged) <- runOk "lodge at Fanlou" atInn (playerTalk "tester" "fanlou_innkeeper")
  assert (questStageOf "first_steps_kaifeng" lodged == Just "training") "lodging did not advance to training"
  case M.lookup "tester" (lodged ^. players) of
    Nothing -> fail "tester missing after lodging"
    Just player -> assert ((player ^. playerInventory . at "kaifeng_room_tag") == Just 1) "inn did not hand over the room tag"

  (_, atTraining) <- runOk "move to training yard" lodged (movePlayerToRoom "tester" "kaifeng_city" (-1, -1))
  (_, readyToPractice) <- runOk "speak with Liang instructor" atTraining (playerTalk "tester" "kaifeng_martial_instructor")
  assert (questStageOf "first_steps_kaifeng" readyToPractice == Just "practice") "instructor did not open the practice fight"
  (_, practiceBattle) <- runOk "start practice fight" readyToPractice (playerTalk "tester" "kaifeng_training_dummy")
  let defeatedDummy = practiceBattle & battles . ix "tester" . battleEnemyState . battleChar . charHP .~ 0
  (_, afterPractice) <- runOk "settle practice fight" defeatedDummy (updateBattle 0 "tester")
  assert (questStageOf "first_steps_kaifeng" afterPractice == Just "first_job") "practice fight did not unlock the first job"

  (_, atScribe) <- runOk "move to scribe" afterPractice (movePlayerToRoom "tester" "kaifeng_city" (1, -1))
  (_, settled) <- runOk "complete first city job" atScribe (playerTalk "tester" "old_scribe")
  assert (questStageOf "first_steps_kaifeng" settled == Just "completed") "first city job did not complete Kaifeng settling"
  case M.lookup "tester" (settled ^. players) of
    Nothing -> fail "tester missing after first city job"
    Just player -> assert ((player ^. playerInventory . at "kaifeng_work_token") == Just 1) "employer did not hand over the work token"

  (_, backAtGuide) <- runOk "return to guide" settled (movePlayerToRoom "tester" "kaifeng_city" (0, -1))
  (_, choosingRoute) <- runOk "ask guide about travel" backAtGuide (playerTalk "tester" "kaifeng_guide")
  assert (questStageOf "three_city_leads" choosingRoute == Just "choose_route") "guide did not open the travel choice"
  (_, atLuoyangRunner) <- runOk "move to Luoyang runner" choosingRoute (movePlayerToRoom "tester" "kaifeng_city" (-2, 2))
  (_, inLuoyang) <- runOk "choose Luoyang as first journey" atLuoyangRunner (playerTalk "tester" "luoyang_runner")
  assert (questStageOf "three_city_leads" inLuoyang == Just "completed") "choosing one route did not complete the travel introduction"
  case M.lookup "tester" (inLuoyang ^. players) of
    Nothing -> fail "tester missing after travel"
    Just player -> do
      assert ((player ^. playerPosition) == ("luoyang_road", (0, 0))) "first journey did not stop on the road"
      assert ((player ^. playerInventory . at "travel_pass") == Just 1) "travel contact did not hand over the route pass"
  assert (questStageOf "journey_luoyang" inLuoyang == Just "road") "road encounter did not start"
  (_, roadFight) <- runOk "answer the drunk swordsman" inLuoyang (playerTalk "tester" "road_drunk_swordsman")
  let beaten = roadFight & battles . ix "tester" . battleEnemyState . battleChar . charHP .~ 0
  (_, arrived) <- runOk "settle road fight" beaten (updateBattle 0 "tester")
  assert (questStageOf "journey_luoyang" arrived == Just "completed") "road encounter did not complete"
  assert (playerAt arrived == Just ("luoyang_city", (0, 0))) "road encounter did not deliver the player to Luoyang"
  (_, home) <- runOk "ride back to Kaifeng" arrived (playerTalk "tester" "luoyang_runner")
  assert (playerAt home == Just ("kaifeng_city", (-2, 2))) "Luoyang runner did not carry the player back to Kaifeng"
  (_, again) <- runOk "ride to Luoyang again" home (playerTalk "tester" "luoyang_runner")
  assert (playerAt again == Just ("luoyang_city", (0, 0))) "repeat trip did not go straight to Luoyang"
  where
    playerAt gs' = view playerPosition <$> M.lookup "tester" (gs' ^. players)

testLegacyPreparedSlotFoldsIntoEnabled :: IO ()
testLegacyPreparedSlotFoldsIntoEnabled = do
  let legacyJson =
        "{\"player_id\":\"tester\",\"version\":6,"
          <> "\"prepared\":{\"sword\":{\"id\":\"weiyuan_sword\",\"level\":3},\"fist\":{\"id\":\"nameless_trial_fist\",\"level\":1}},"
          <> "\"enabled\":{\"sword\":{\"id\":\"nameless_trial_sword\",\"level\":1}}}"
  case eitherDecode legacyJson of
    Left err -> fail $ "legacy save did not decode: " <> err
    Right save -> do
      let enabled = saveEnabled save
      assert (fmap (view artDef) (M.lookup Sword enabled) == Just "nameless_trial_sword") "explicit enabled art should win over prepared"
      assert (fmap (view artDef) (M.lookup Fist enabled) == Just "nameless_trial_fist") "prepared-only art was not folded into enabled"

testPlayerSaveRoundTrip :: IO ()
testPlayerSaveRoundTrip = do
  gs <- newTestPlayerState
  let fixtureQuestId = "fixture_quest"
      accepted =
        gs
          & stories . ix "tester" . storyQuestStages . at fixtureQuestId ?~ "accepted"
  let rewarded =
        accepted
          & players . ix "tester" . playerPosition .~ ("kaifeng_city", (0, 1))
          & players . ix "tester" . playerMoney .~ 80
          & players . ix "tester" . playerPotential .~ 12
          & players . ix "tester" . playerCombatExp .~ 345
          & players . ix "tester" . playerInventory . at "saved_token" .~ Just 1
          & players . ix "tester" . playerInventory . at "saved_manual" .~ Just 1
          & players . ix "tester" . playerCharacter . charQi .~ 72
          & players . ix "tester" . playerCharacter . charMaxQi .~ 123
          & players . ix "tester" . playerCharacter . charJing .~ 91
          & players . ix "tester" . playerCharacter . charDesc .~ "我从汴梁来。"
          & players . ix "tester" . playerCharacter . charGender .~ Female
          & players . ix "tester" . playerCharacter . charAppearance .~ 8
          & players . ix "tester" . playerCharacter . charInnate .~ InnateAttrs 21 17 16
          & players . ix "tester" . playerCharacter . charArt . at Foundation .~ Just [ArtEntity "basic_sword" 5 0]
          & players . ix "tester" . playerCharacter . charArt . at Sword .~ Just [ArtEntity "saved_sword_art" 5 0]
          & players . ix "tester" . playerCharacter . charEnabled . at Sword .~ Just (ArtEntity "saved_sword_art" 5 0)
  savePlayerState ".stack-work/test-saves" "tester" rewarded
  saveResult <- loadPlayerSave ".stack-work/test-saves" "tester"
  save <- case saveResult of
    Left err -> fail $ "failed to load player save: " <> T.unpack err
    Right Nothing -> fail "player save was not written"
    Right (Just loaded) -> pure loaded
  assert (saveVersion save == 6) "player save version was not bumped"
  fresh <- newTestPlayerState
  let restored = applyPlayerSaveToGameState save fresh
  assert (questStageOf fixtureQuestId restored == Just "accepted") "saved quest stage was not restored"
  case M.lookup "tester" (restored ^. players) of
    Nothing -> fail "tester missing after save restore"
    Just player -> do
      assert ((player ^. playerMoney) == 80) "saved money was not restored"
      assert ((player ^. playerPosition) == ("kaifeng_city", (0, 1))) "saved player position was not restored"
      assert ((player ^. playerPotential) == 12) "saved potential was not restored"
      assert ((player ^. playerCombatExp) == 345) "saved combat exp was not restored"
      assert ((player ^. playerInventory . at "saved_token") == Just 1) "saved inventory was not restored"
      assert ((player ^. playerInventory . at "saved_manual") == Just 1) "saved manual inventory was not restored"
      assert ((player ^. playerCharacter . charQi) == 72) "saved qi was not restored"
      assert ((player ^. playerCharacter . charMaxQi) == 123) "saved max qi was not restored"
      assert ((player ^. playerCharacter . charJing) == 91) "saved jing was not restored"
      assert ((player ^. playerCharacter . charDesc) == "我从汴梁来。") "saved desc was not restored"
      assert ((player ^. playerCharacter . charGender) == Female) "saved gender was not restored"
      assert ((player ^. playerCharacter . charAppearance) == 8) "saved appearance was not restored"
      assert ((player ^. playerCharacter . charInnate) == InnateAttrs 21 17 16) "saved innate attrs were not restored"
      assert ((player ^. playerCharacter . charArt . at Foundation) == Just [ArtEntity "basic_sword" 5 0]) "saved foundation art was not restored"
      assert ((player ^. playerCharacter . charArt . at Sword) == Just [ArtEntity "saved_sword_art" 5 0]) "saved learned martial art was not restored"
      assert ((player ^. playerCharacter . charEnabled . at Sword) == Just (ArtEntity "saved_sword_art" 5 0)) "saved enabled martial art was not restored"
      assert (S.member "tester" $ roomPlayersAtMap "kaifeng_city" restored (0, 1)) "restored room occupancy did not include the player"
      assert (not $ S.member "tester" $ roomPlayersAt restored (3, 3)) "default room occupancy still contained the restored player"
  let legacyRestored = applyPlayerSaveToGameState (save {saveVersion = 5}) fresh
  assert (questStageOf fixtureQuestId legacyRestored == Nothing) "pre-migration story ids were restored"
  case M.lookup "tester" (legacyRestored ^. players) of
    Nothing -> fail "tester missing after legacy save restore"
    Just player ->
      assert ((player ^. playerPosition) == ("weiyuan_road", (3, 3))) "pre-migration position was restored"

testRepeatableJobsAndStreaks :: IO ()
testRepeatableJobsAndStreaks = do
  gs0 <- newTestPlayerState
  let gs1 =
        gs0
          & stories . ix "tester" . storyQuestStages . at "first_steps_kaifeng" ?~ "completed"
          & players . ix "tester" . playerPosition .~ ("kaifeng_city", (2, 3))
          & players . ix "tester" . playerMoney .~ 0
          & players . ix "tester" . playerCombatExp .~ 0
          & players . ix "tester" . playerPotential .~ 0
  -- First run (streak 1 -> 100%)
  (_, gs2) <- runOk "start post job 1" gs1 $ processNormalAction "tester" (Talk "post_runner")
  assert (questStageOf "job_kaifeng_post_run" gs2 == Just "carry_dispatch") "post job did not start"
  let gs2AtPost = gs2 & players . ix "tester" . playerPosition .~ ("north_post_road", (0, 1))
  (_, gs3) <- runOk "deliver post 1" gs2AtPost $ processNormalAction "tester" (Go North)
  assert (questStageOf "job_kaifeng_post_run" gs3 == Just "delivered") "post job did not advance on entering relay pavilion"
  let gs3Back = gs3 & players . ix "tester" . playerPosition .~ ("kaifeng_city", (2, 3))
  (res1, gs4) <- runOk "finish post job 1" gs3Back $ processNormalAction "tester" (Talk "post_runner")
  assert (isNothing $ questStageOf "job_kaifeng_post_run" gs4) "repeatable job stage should clear after completion"
  assert (gs4 ^? stories . ix "tester" . storyJobStreaks . ix "job_kaifeng_post_run" == Just 1) "job streak should be 1"
  assert (any (\case SystemMsg (SystemMessage "job_completed" _) -> True; _ -> False) (map snd res1)) "job_completed system message missing"
  let money1 = fromMaybe 0 (gs4 ^? players . ix "tester" . playerMoney)
      exp1 = fromMaybe 0 (gs4 ^? players . ix "tester" . playerCombatExp)
  assert (money1 == 28 && exp1 == 35) "first streak reward should be 100% of base"
  -- Second run (streak 2 -> 115%)
  (_, gs5) <- runOk "start post job 2" gs4 $ processNormalAction "tester" (Talk "post_runner")
  assert (questStageOf "job_kaifeng_post_run" gs5 == Just "carry_dispatch") "repeatable job should be re-acceptable"
  let gs5AtPost = gs5 & players . ix "tester" . playerPosition .~ ("north_post_road", (0, 1))
  (_, gs6) <- runOk "deliver post 2" gs5AtPost $ processNormalAction "tester" (Go North)
  let gs6Back = gs6 & players . ix "tester" . playerPosition .~ ("kaifeng_city", (2, 3))
  (_, gs7) <- runOk "finish post job 2" gs6Back $ processNormalAction "tester" (Talk "post_runner")
  assert (gs7 ^? stories . ix "tester" . storyJobStreaks . ix "job_kaifeng_post_run" == Just 2) "job streak should be 2"
  let moneyDelta2 = fromMaybe 0 (gs7 ^? players . ix "tester" . playerMoney) - money1
      expDelta2 = fromMaybe 0 (gs7 ^? players . ix "tester" . playerCombatExp) - exp1
  assert (moneyDelta2 == jobStreakScale 2 28 && expDelta2 == jobStreakScale 2 35) "second streak reward should scale to 115%"

testShopEquipmentMedicineAndWeaponStyle :: IO ()
testShopEquipmentMedicineAndWeaponStyle = do
  gs0 <- newTestPlayerState
  let gs1 =
        gs0
          & players . ix "tester" . playerPosition .~ ("kaifeng_city", (3, 1))
          & players . ix "tester" . playerMoney .~ 200
          & players . ix "tester" . playerCharacter . charEnabled . at Sword ?~ ArtEntity "nameless_trial_sword" 5 0
          & players . ix "tester" . playerCharacter . charEnabled . at Fist ?~ ArtEntity "nameless_trial_fist" 5 0
  let baseDerived = deriveStats (gs1 ^?! players . ix "tester")
  -- Buy sword and armor from blacksmith
  (_, gs2) <- runOk "buy sword" gs1 $ processNormalAction "tester" (Buy (Just "kaifeng_blacksmith") "qinggang_sword")
  (_, gs3) <- runOk "buy armor" gs2 $ processNormalAction "tester" (Buy (Just "kaifeng_blacksmith") "patrol_leather_armor")
  assert (gs3 ^? players . ix "tester" . playerMoney == Just (200 - 45 - 48)) "buying should deduct copper"
  -- Equip both
  (_, gs4) <- runOk "equip sword" gs3 $ processNormalAction "tester" (Equip "qinggang_sword")
  (_, gs5) <- runOk "equip armor" gs4 $ processNormalAction "tester" (Equip "patrol_leather_armor")
  let pEquipped = gs5 ^?! players . ix "tester"
      eqDerived = deriveStats pEquipped
  assert (eqDerived ^. dsDamageBonus > baseDerived ^. dsDamageBonus) "equipping sword should increase damage bonus"
  assert (eqDerived ^. dsMaxHp == baseDerived ^. dsMaxHp + 25) "equipping armor should increase max HP"
  let swordAttacks = unlockedPreparedAttacks (gs5 ^. world . martialArts) (pEquipped ^. playerCharacter)
  assert (not (null swordAttacks) && all (\(PreparedAttack _ art _) -> art ^. artType == Sword) swordAttacks) "wielding sword should select sword moves only"
  -- Equip fist bracers and verify fist moves only
  (_, gs6) <- runOk "buy bracers" gs5 $ processNormalAction "tester" (Buy (Just "kaifeng_blacksmith") "iron_fist_bracers")
  (_, gs7) <- runOk "equip bracers" gs6 $ processNormalAction "tester" (Use "iron_fist_bracers")
  let pFist = gs7 ^?! players . ix "tester"
      fistAttacks = unlockedPreparedAttacks (gs7 ^. world . martialArts) (pFist ^. playerCharacter)
  assert (not (null fistAttacks) && all (\(PreparedAttack _ art _) -> art ^. artType == Fist) fistAttacks) "wielding fist bracers should select fist moves only"
  -- Save and reload equipped items
  savePlayerState ".stack-work/test-saves" "tester-equip" (gs7 & players . at "tester-equip" .~ gs7 ^. players . at "tester")
  savedRes <- loadPlayerSave ".stack-work/test-saves" "tester-equip"
  loadedSave <- case savedRes of
    Right (Just s) -> pure s
    other -> fail $ "failed loading equip save: " <> show other
  assert (M.lookup WeaponSlot (saveEquipped loadedSave) == Just "iron_fist_bracers") "equipped weapon should persist in save"
  assert (M.lookup ArmorSlot (saveEquipped loadedSave) == Just "patrol_leather_armor") "equipped armor should persist in save"
  -- Medicine heals HP and cures injury
  let gsApothecary =
        gs7
          & players . ix "tester" . playerPosition .~ ("kaifeng_city", (2, -1))
          & players . ix "tester" . playerCharacter . charHP .~ 20
          & playerRuntime . at "tester" ?~ (newPlayerRuntime & runtimeInjuredRemaining .~ 120)
  (_, gsBoughtMed) <- runOk "buy wound powder" gsApothecary $ processNormalAction "tester" (Buy (Just "kaifeng_physician") "wound_powder")
  (_, gsHealed) <- runOk "use wound powder" gsBoughtMed $ processNormalAction "tester" (Use "wound_powder")
  assert (gsHealed ^? players . ix "tester" . playerCharacter . charHP == Just 65) "wound powder should restore 45 HP"
  assert (gsHealed ^? playerRuntime . ix "tester" . runtimeInjuredRemaining == Just 60) "wound powder should reduce injury by 60s"

testRoomAndCombatInsightBonuses :: IO ()
testRoomAndCombatInsightBonuses = do
  gs0 <- newTestPlayerState
  let baseSetup pos insightStacks =
        gs0
          & players . ix "tester" . playerPosition .~ pos
          & players . ix "tester" . playerPotential .~ 10
          & players . ix "tester" . playerCombatExp .~ 100000
          & players . ix "tester" . playerCharacter . charJing .~ 120
          & players . ix "tester" . playerCharacter . charArt . at Sword ?~ [ArtEntity "luoyang_sword" 20 0]
          & playerRuntime . at "tester" ?~ (newPlayerRuntime & runtimeCombatInsight .~ insightStacks)
  -- Research in a normal room (kaifeng_south_street) without combat insight
  (_, gsPlain) <- runOk "research plain" (baseSetup ("kaifeng_city", (0, 0)) 0) $ processNormalAction "tester" (Research "luoyang_sword" 1)
  (_, gsPlainDone) <- runOk "tick plain" gsPlain $ tickTraining 5.0
  -- Research in Baima Stele Pavilion (bonus 8, jing_discount 4) with 2 combat insight stacks (+6)
  (_, gsInsight) <- runOk "research insight" (baseSetup ("luoyang_city", (-1, 7)) 2) $ processNormalAction "tester" (Research "luoyang_sword" 1)
  (_, gsInsightDone) <- runOk "tick insight" gsInsight $ tickTraining 5.0
  let plainProg = fromMaybe 0 . listToMaybe $ [a ^. artProgress | a <- fromMaybe [] (gsPlainDone ^? players . ix "tester" . playerCharacter . charArt . ix Sword), a ^. artDef == "luoyang_sword"]
      insightProg = fromMaybe 0 . listToMaybe $ [a ^. artProgress | a <- fromMaybe [] (gsInsightDone ^? players . ix "tester" . playerCharacter . charArt . ix Sword), a ^. artDef == "luoyang_sword"]
      plainJing = fromMaybe 0 (gsPlainDone ^? players . ix "tester" . playerCharacter . charJing)
      insightJing = fromMaybe 0 (gsInsightDone ^? players . ix "tester" . playerCharacter . charJing)
  assert (insightProg == plainProg + 8 + combatInsightResearchBonus) "room insight + combat insight should boost research progress"
  assert (insightJing == plainJing + 4) "room insight jing_discount should reduce research Jing cost"
  assert (gsInsightDone ^? playerRuntime . ix "tester" . runtimeCombatInsight == Just 1) "research step should consume 1 combat insight stack"

testInternalArtDifferentiation :: IO ()
testInternalArtDifferentiation = do
  gs0 <- newTestPlayerState
  let gsTaihu =
        gs0
          & players . ix "tester" . playerCharacter . charEnabled . at Internal ?~ ArtEntity "taihu_breath" 15 0
          & players . ix "tester" . playerCharacter . charHP .~ 50
          & playerRuntime . at "tester" ?~ (newPlayerRuntime & runtimeInjuredRemaining .~ 60)
      gsPlain =
        gs0
          & players . ix "tester" . playerCharacter . charEnabled . at Internal .~ Nothing
          & players . ix "tester" . playerCharacter . charHP .~ 50
          & playerRuntime . at "tester" ?~ (newPlayerRuntime & runtimeInjuredRemaining .~ 60)
  (_, gsTaihuTick) <- runOk "tick taihu" gsTaihu $ tickPlayerRecovery 10.0
  (_, gsPlainTick) <- runOk "tick plain" gsPlain $ tickPlayerRecovery 10.0
  let taihuInj = fromMaybe 60 (gsTaihuTick ^? playerRuntime . ix "tester" . runtimeInjuredRemaining)
      plainInj = fromMaybe 60 (gsPlainTick ^? playerRuntime . ix "tester" . runtimeInjuredRemaining)
  assert (taihuInj < plainInj) "taihu_breath should speed up injury recovery"
  -- Duan Zen Breath meditation bonus & defensive derived stats
  let gsZen =
        gs0
          & players . ix "tester" . playerCharacter . charEnabled . at Internal ?~ ArtEntity "duan_zen_breath" 20 0
          & players . ix "tester" . playerCharacter . charArt . at Foundation ?~ [ArtEntity "basic_internal" 20 0]
          & players . ix "tester" . playerCharacter . charQi .~ 100
          & players . ix "tester" . playerCharacter . charMaxQi .~ 100
      gsNoZen =
        gs0
          & players . ix "tester" . playerCharacter . charEnabled . at Internal ?~ ArtEntity "taihu_breath" 20 0
          & players . ix "tester" . playerCharacter . charArt . at Foundation ?~ [ArtEntity "basic_internal" 20 0]
          & players . ix "tester" . playerCharacter . charQi .~ 100
          & players . ix "tester" . playerCharacter . charMaxQi .~ 100
  let zenDerived = deriveStats (gsZen ^?! players . ix "tester")
      noZenDerived = deriveStats (gsNoZen ^?! players . ix "tester")
  assert (zenDerived ^. dsDamageReduction > noZenDerived ^. dsDamageReduction) "duan_zen_breath should provide damage reduction"
  (_, gsZenMed) <- runOk "meditate zen" gsZen $ processNormalAction "tester" (Meditate 20 1)
  (_, gsZenDone) <- runOk "tick zen med" gsZenMed $ tickTraining 5.0
  (_, gsNoZenMed) <- runOk "meditate no zen" gsNoZen $ processNormalAction "tester" (Meditate 20 1)
  (_, gsNoZenDone) <- runOk "tick no zen med" gsNoZenMed $ tickTraining 5.0
  let zenMaxQi = fromMaybe 0 (gsZenDone ^? players . ix "tester" . playerCharacter . charMaxQi)
      noZenMaxQi = fromMaybe 0 (gsNoZenDone ^? players . ix "tester" . playerCharacter . charMaxQi)
  assert (zenMaxQi > noZenMaxQi) "duan_zen_breath should grant extra max Qi per meditation"
