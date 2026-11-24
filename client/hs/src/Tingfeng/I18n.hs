{-# LANGUAGE OverloadedStrings #-}

module Tingfeng.I18n
  ( Locale (..),
    localeText,
    parseLocale,
    tr,
    trParams,
    artRankTitle,
    formatArtType,
    formatSystemMsg,
    formatErrorMsg,
  )
where

import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

data Locale = Zh | En
  deriving (Show, Eq)

localeText :: Locale -> Text
localeText Zh = "zh"
localeText En = "en"

parseLocale :: Text -> Locale
parseLocale "en" = En
parseLocale _ = Zh

tr :: Locale -> Text -> Text
tr loc key =
  let tbl = if loc == Zh then zhTable else enTable
   in fromMaybe (fromMaybe key (M.lookup key zhTable)) (M.lookup key tbl)

trParams :: Locale -> Text -> [(Text, Text)] -> Text
trParams loc key kvs =
  foldl' (\acc (k, v) -> T.replace ("{" <> k <> "}") v acc) (tr loc key) kvs

artRankTitle :: Locale -> Int -> Text
artRankTitle loc lvl
  | lvl >= 90 = tr loc "art.rank.90"
  | lvl >= 70 = tr loc "art.rank.70"
  | lvl >= 50 = tr loc "art.rank.50"
  | lvl >= 35 = tr loc "art.rank.35"
  | lvl >= 20 = tr loc "art.rank.20"
  | lvl >= 10 = tr loc "art.rank.10"
  | otherwise = tr loc "art.rank.1"

formatArtType :: Locale -> Text -> Text
formatArtType loc raw =
  let k = "art.type." <> T.toLower raw
      v = tr loc k
   in if v == k then raw else v

formatSystemMsg :: Locale -> Text -> M.Map Text Text -> Text
formatSystemMsg loc code params =
  let key = "system." <> code
      base = tr loc key
   in if base == key
        then trParams loc "system.unknown" [("code", code)]
        else trParams loc key (M.toList params)

formatErrorMsg :: Locale -> Text -> M.Map Text Text -> Text
formatErrorMsg loc code params =
  let key = "error." <> code
      base = tr loc key
   in if base == key
        then case M.lookup "message" params of
          Just m | not (T.null m) -> m
          _ -> trParams loc "error.unknown" [("code", code)]
        else trParams loc key (M.toList params)

zhTable :: M.Map Text Text
zhTable =
  M.fromList
    [ ("app.title", "听风录"),
      ("connection.connected", "已连接"),
      ("connection.disconnected", "未连接"),
      ("connection.connecting", "正在连接 {user}..."),
      ("connection.ready", "已连入江湖。"),
      ("connection.closed", "已断开连接。"),
      ("error.username_required", "请输入用户名。"),
      ("error.dev_mode_required", "测试重置需要用 MUD_DEV_MODE=1 启动 server。"),
      ("error.unable_to_move", "不能从{room}往{direction}走。"),
      ("error.unable_to_interact", "现在不能对{target}执行「{action}」。"),
      ("error.item_cannot_be_used", "现在不能使用{item}。"),
      ("error.item_not_in_inventory", "背包里没有这个物品：{itemId}"),
      ("error.art_not_learned", "你尚未学会{art}。"),
      ("error.art_already_max", "{art}已经修炼到顶。"),
      ("error.foundation_art_cannot_train", "{art}不能直接修炼。"),
      ("error.cannot_learn_art", "不能学习{art}，需要：{requirements}。"),
      ("error.not_enough_jing", "精神不足，需要 {required}，当前 {current}。"),
      ("error.teacher_refuses", "{teacher}：{reason}"),
      ("error.teacher_cannot_teach_art", "{teacher}不教这门武功。"),
      ("error.teacher_art_level_cap", "{teacher}只能把{art}教到 {max} 级。"),
      ("error.player_busy", "正忙着，还要 {seconds} 秒。"),
      ("error.player_injured", "伤势未愈，{seconds} 秒内不宜动手。"),
      ("error.not_enough_hp", "气血不足，练功需要 {required}，当前 {current}。"),
      ("error.not_enough_qi", "内力不足，需要 {required}，当前 {current}。"),
      ("error.not_enough_potential", "潜能不足，需要 {required}，当前 {current}。"),
      ("error.combat_exp_too_low", "实战经验不足：练到 {level} 级需要 {required}，当前 {current}。"),
      ("error.research_too_early", "{art}要练到 {level} 级才能自行钻研。"),
      ("error.book_exhausted", "{item}已经读不出新东西了。"),
      ("error.book_too_advanced", "{item}太深，要先练到 {level} 级。"),
      ("error.max_qi_at_cap", "内功火候不足，内力上限已到 {cap}。"),
      ("error.foundation_art_cannot_research", "{art}不能自研。"),
      ("error.foundation_art_cannot_enable", "基础功不能启用。"),
      ("error.item_cannot_be_studied", "{item}没什么可研读的。"),
      ("error.item_cannot_be_equipped", "{item}不能穿戴。"),
      ("error.slot_not_equipped", "该部位当前未穿戴装备。"),
      ("error.merchant_not_carrying_item", "此处没有出售这件物品。"),
      ("error.not_enough_money", "碎银不足，需要 {required}，当前 {current}。"),
      ("error.unknown", "错误：{code}"),
      ("system.art_enabled", "启用的武功已更换。"),
      ("system.item_bought", "在{merchant}处花费 {price} 碎银买下了{item}。"),
      ("system.job_completed", "完成了【{job}】（当前连环第 {streak} 趟）。"),
      ("system.combat_insight_gained", "此战略有心得，获得 {stacks} 层实战印证（后续练功/自研受益提升）。"),
      ("system.battle_reward_none", "与{enemy}这一战，已经练不出什么长进了。"),
      ("system.potential_full", "潜能已满（上限 {cap}），该去学些东西了。"),
      ("system.training_finished", "{action}告一段落，共 {completed} 次。"),
      ("system.training_halted", "{action}中止，完成了 {completed} 次。"),
      ("system.training_stopped", "{action}停下，完成了 {completed} 次。"),
      ("system.welcome", "已进入江湖。当前在线：{users}"),
      ("system.user_joined", "{user} 已进入江湖。"),
      ("system.user_disconnected", "{user} 已离开。"),
      ("system.unknown", "系统消息：{code}"),
      ("training.action.practice", "练功"),
      ("training.action.learn", "学艺"),
      ("training.action.study", "研读"),
      ("training.action.research", "自研"),
      ("training.action.meditate", "打坐"),
      ("action.practice", "练功"),
      ("action.practice_many", "练十次"),
      ("action.research", "自研"),
      ("action.enable", "启用"),
      ("action.enabled", "已启用"),
      ("action.learn", "学艺"),
      ("action.learn_many", "学十次"),
      ("action.study", "研读"),
      ("action.meditate", "打坐"),
      ("action.halt", "停下"),
      ("action.buy", "购买"),
      ("action.equip", "佩带"),
      ("action.unequip", "卸下"),
      ("action.talk", "交谈"),
      ("action.attack", "攻击"),
      ("action.spar", "切磋"),
      ("action.use", "使用"),
      ("action.send", "发送"),
      ("action.clear", "清屏"),
      ("action.close", "关闭"),
      ("action.refresh", "刷新"),
      ("art.rank.1", "初学乍练"),
      ("art.rank.10", "粗通皮毛"),
      ("art.rank.20", "略有小成"),
      ("art.rank.35", "驾轻就熟"),
      ("art.rank.50", "融会贯通"),
      ("art.rank.70", "炉火纯青"),
      ("art.rank.90", "登峰造极"),
      ("art.blocker.combat_exp", "实战不足：下一级需实战经验 {required}"),
      ("art.blocker.foundation", "已追上根基，再练只长基础功"),
      ("art.blocker.max_level", "已至顶"),
      ("art.level", "{level}/{max} 重"),
      ("art.type.foundation", "基础功"),
      ("art.type.internal", "内功"),
      ("art.type.lightness", "轻功"),
      ("art.type.sword", "剑法"),
      ("art.type.fist", "拳法"),
      ("panel.character", "角色"),
      ("panel.inventory", "背包"),
      ("panel.arts", "武学"),
      ("panel.quest", "任务"),
      ("panel.messages", "江湖纪事"),
      ("panel.innate", "先天属性"),
      ("panel.effects", "状态"),
      ("nav.world", "江湖"),
      ("nav.battle", "交锋"),
      ("nav.log", "纪事"),
      ("nav.arts", "武学"),
      ("nav.character", "角色"),
      ("nav.quests", "任务"),
      ("resource.hp", "气血"),
      ("resource.qi", "内力"),
      ("resource.jing", "精神"),
      ("resource.ap", "行动"),
      ("field.money", "碎银"),
      ("field.potential", "潜能"),
      ("field.combat_exp", "实战经验"),
      ("field.appearance", "容貌"),
      ("field.combat_insight", "实战印证"),
      ("attr.strength", "臂力"),
      ("attr.agility", "身法"),
      ("attr.vitality", "根骨"),
      ("gender.male", "男"),
      ("gender.female", "女"),
      ("gender.unknown", "未定"),
      ("npc.teaches", "可传武学"),
      ("npc.teach_cap", "教到 {max} 级"),
      ("npc.shop", "行商货架"),
      ("inventory.equipped", "已佩带"),
      ("quest.completed", "已完成"),
      ("quest.active", "进行中"),
      ("quest.reward", "奖励：{value}"),
      ("ui.none", "暂无"),
      ("ui.command_placeholder", "输入发言，回车发送...")
    ]

enTable :: M.Map Text Text
enTable =
  M.fromList
    [ ("app.title", "Tingfeng"),
      ("connection.connected", "Connected"),
      ("connection.disconnected", "Disconnected"),
      ("connection.connecting", "Connecting {user}..."),
      ("connection.ready", "Connected to Jianghu."),
      ("connection.closed", "Disconnected."),
      ("error.username_required", "Enter a username."),
      ("error.dev_mode_required", "Test reset requires MUD_DEV_MODE=1 on the server."),
      ("error.unable_to_move", "Cannot move {direction} from {room}."),
      ("error.not_enough_jing", "Not enough spirit: need {required}, current {current}."),
      ("error.teacher_refuses", "{teacher}: {reason}"),
      ("error.teacher_cannot_teach_art", "{teacher} does not teach this art."),
      ("error.teacher_art_level_cap", "{teacher} can only teach {art} up to level {max}."),
      ("error.player_busy", "Busy for another {seconds}s."),
      ("error.player_injured", "Still injured; avoid fighting for {seconds}s."),
      ("error.not_enough_hp", "Not enough HP to practise: need {required}, current {current}."),
      ("error.not_enough_qi", "Not enough Qi: need {required}, current {current}."),
      ("error.not_enough_potential", "Not enough potential: need {required}, current {current}."),
      ("error.combat_exp_too_low", "Need {required} combat exp for level {level} (current {current})."),
      ("error.research_too_early", "{art} must reach level {level} before researching."),
      ("error.book_exhausted", "{item} has nothing more to teach you."),
      ("error.book_too_advanced", "{item} is too deep; reach level {level} first."),
      ("error.max_qi_at_cap", "Max Qi capped at {cap}."),
      ("error.not_enough_money", "Not enough money: need {required}, current {current}."),
      ("error.unknown", "Error: {code}"),
      ("system.art_enabled", "Enabled art changed."),
      ("system.item_bought", "Bought {item} from {merchant} for {price} copper."),
      ("system.job_completed", "Completed {job} (streak {streak})."),
      ("system.combat_insight_gained", "Gained {stacks} stacks of combat insight."),
      ("system.battle_reward_none", "Nothing more to learn from fighting {enemy}."),
      ("system.potential_full", "Potential is full (cap {cap})."),
      ("system.training_finished", "{action} finished ({completed}x)."),
      ("system.training_halted", "{action} halted ({completed}x)."),
      ("system.training_stopped", "{action} stopped ({completed}x)."),
      ("system.welcome", "Welcome. Online: {users}"),
      ("system.user_joined", "{user} joined."),
      ("system.user_disconnected", "{user} left."),
      ("system.unknown", "System: {code}"),
      ("training.action.practice", "Practice"),
      ("training.action.learn", "Lesson"),
      ("training.action.study", "Study"),
      ("training.action.research", "Research"),
      ("training.action.meditate", "Meditation"),
      ("action.practice", "Practice"),
      ("action.practice_many", "x10"),
      ("action.research", "Research"),
      ("action.enable", "Enable"),
      ("action.enabled", "Enabled"),
      ("action.learn", "Learn"),
      ("action.learn_many", "x10"),
      ("action.study", "Study"),
      ("action.meditate", "Meditate"),
      ("action.halt", "Stop"),
      ("action.buy", "Buy"),
      ("action.equip", "Equip"),
      ("action.unequip", "Unequip"),
      ("action.talk", "Talk"),
      ("action.attack", "Attack"),
      ("action.spar", "Spar"),
      ("action.use", "Use"),
      ("action.send", "Send"),
      ("action.clear", "Clear"),
      ("action.close", "Close"),
      ("action.refresh", "Refresh"),
      ("art.rank.1", "Novice"),
      ("art.rank.10", "Apprentice"),
      ("art.rank.20", "Adept"),
      ("art.rank.35", "Skilled"),
      ("art.rank.50", "Expert"),
      ("art.rank.70", "Master"),
      ("art.rank.90", "Grandmaster"),
      ("art.blocker.combat_exp", "Needs {required} combat exp for next level"),
      ("art.blocker.foundation", "Caught up with foundation"),
      ("art.blocker.max_level", "Maxed"),
      ("art.level", "Lv.{level}/{max}"),
      ("art.type.foundation", "Foundation"),
      ("art.type.internal", "Internal"),
      ("art.type.lightness", "Lightness"),
      ("art.type.sword", "Sword"),
      ("art.type.fist", "Fist"),
      ("panel.character", "Character"),
      ("panel.inventory", "Bag"),
      ("panel.arts", "Arts"),
      ("panel.quest", "Quests"),
      ("panel.messages", "Log"),
      ("panel.innate", "Innate"),
      ("panel.effects", "Effects"),
      ("nav.world", "World"),
      ("nav.battle", "Battle"),
      ("nav.log", "Log"),
      ("nav.arts", "Arts"),
      ("nav.character", "Hero"),
      ("nav.quests", "Quests"),
      ("resource.hp", "HP"),
      ("resource.qi", "Qi"),
      ("resource.jing", "Spirit"),
      ("resource.ap", "AP"),
      ("field.money", "Silver"),
      ("field.potential", "Potential"),
      ("field.combat_exp", "Combat Exp"),
      ("field.appearance", "Looks"),
      ("field.combat_insight", "Insight"),
      ("attr.strength", "STR"),
      ("attr.agility", "AGI"),
      ("attr.vitality", "VIT"),
      ("gender.male", "Male"),
      ("gender.female", "Female"),
      ("gender.unknown", "Unset"),
      ("npc.teaches", "Teaches"),
      ("npc.teach_cap", "up to Lv.{max}"),
      ("npc.shop", "Merchant"),
      ("inventory.equipped", "Equipped"),
      ("quest.completed", "Done"),
      ("quest.active", "Active"),
      ("quest.reward", "Reward: {value}"),
      ("ui.none", "None"),
      ("ui.command_placeholder", "Say something...")
    ]
