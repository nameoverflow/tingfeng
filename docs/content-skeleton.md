# 内容骨架规划

本文负责地图、NPC、任务和城市规模。剧情因果、玩家动机和威远旧线的回响原则以 [主线剧情大纲](./story-outline.md) 为准。

## 第一阶段规模

- 中心大城：`开封府`，古称汴梁。
- 序章地点：`开封城外破庙`、`汴水官道`、`威远分局`（门口、前厅、内院）。
- 大城骨架：`洛阳`、`大理`。
- 小地点：`北郊递道`、`太湖水榭`。
- 远行路段：`西行驿路`、`南下商路`、`东去药路`，各一个房间，承载首次远行的路上事件。
- 后续扩展：`少室山`、`武当山`、`华山道`与五岳诸山。

首阶段不追求传统 MUD 的数千房间规模，优先保证每条已开放路线都有明确的生活功能、人物关系和往返理由。

## 世界入口

序章“威远镖局旧案”只负责把玩家送进江湖：

```text
开封城外破庙
  -> 击退追兵
  -> 老镖师临终托付
  -> 沿汴水官道护送少年
  -> 抵达汴水南渡
  -> 威远分局前厅
  -> 少年冲进内院，留书出走
  -> 差役赶到，玩家从后门绕到柳岸码头
  -> 玩家从南门进入开封，开始自己的生活
```

序章完成后不自动开启威远调查任务。水浸路单作为远期暗线物件保留在玩家背包，少年去向只记录为剧情 flag。

## 开封府

开封承担第一阶段主要生活功能。官府与本地人称开封或府城，汴梁只作为古称与江湖旧称出现：

- 樊楼客舍：住宿和城市落点。
- 南门武馆、南门演武场：基础学习、试招和老师入口。
- 府学、铁铺、药铺：第一份工作及出身差异对白。
- 开封府捕房、驿馆与递铺：巡查、送信和追捕。
- 钱庄、当铺、茶楼、公告墙：经济、消息和后续社交入口。公告墙和茶楼会随剧情 flag 传出威远案的风声。
- 柳岸码头与船棚：汴河漕帮的地盘，开封第一个江湖势力入口。
- 威远分局：序章后按 flag 显示封条现场，总局镖头罗万川会在门口出现。
- 鼓楼西侧的洛阳车马行、北街东侧转运区的大理商队和太湖药车：有叙事过程的远行交通。

玩家完成“开封落脚”后，应能自由选择练功、挣钱、巡查或远行，不需要继续围绕威远灭门案行动。

## 洛阳、大理与太湖

当前通过剧情 flag 与老师 `teach_requires` 表达门户与内堂信任：

- 洛阳：名帖、牡丹台试剑、残谱室、洛水旧堰亭、白马寺（外山门、古碑亭、山门茶寮）与剑法/轻功路线（《洛阳剑法》、《洛水行云步》）。
- 大理：商队、段氏旧府、苍山冷泉涧与废石场、洱海旧渡口、崇圣寺（山门、三塔院）及掌法/禅息路线（《茶马护身拳》、《苍山裂石掌》、《枯荣禅息》）。段氏是前朝王族后裔，不掌当朝政权。
- 太湖：药车、水榭各房、芦苇暗港、雾柳栈桥、听雨荷亭，以及调息/身法/剑法路线（《太湖调息》、《烟波步》、《拂柳剑法》）。

三处区域通过接引 NPC 进入，也通过同一批接引人返回。城市地图没有一步跨回开封的出口。每条路第一次走都会停在路段地图，路上事件办完才进城，并取得该城的门户 flag；之后凭同行帖直达。

后续正式门派系统应再补：

```text
Faction YAML
  -> Teacher binding
  -> apprentice requirements
  -> contribution and reputation
  -> faction jobs
  -> detach consequences
```

## 北郊递道

北郊递道（地图 id `north_post_road`）是开封北门外到黄河南堤与南渡津口的递路与河防交界区：

- 递铺亭触发公文失信追踪，西侧小径出现截信探子（`north_road_patrol`）。
- 黄河南堤向西通南堤芦苇滩（承接开封水陆暗线 `caoban_canal_shadow`），向东通旧烽火台墩，向北通黄河南渡津口。
- 当玩家在洛阳、大理或太湖发现威远旧物上的暗墨线线索后，废军祠会触发威远旧案的第一次正式回响（`weiyuan_first_echo`）。

## 当前已落资源

- `resources/scripts/maps/weiyuan_road.yaml`
- `resources/scripts/maps/bianshui_road.yaml`
- `resources/scripts/maps/kaifeng_city.yaml`
- `resources/scripts/maps/north_post_road.yaml`
- `resources/scripts/maps/luoyang_city.yaml`
- `resources/scripts/maps/dali_city.yaml`
- `resources/scripts/maps/taihu_water_pavilion.yaml`
- `resources/scripts/maps/luoyang_road.yaml`、`dali_road.yaml`、`taihu_road.yaml`
- `resources/scripts/quests/weiyuan_bloody_case.yaml`
- `resources/scripts/quests/content_skeleton_quests.yaml`
- `resources/scripts/quests/kaifeng_jianghu.yaml`
- `resources/scripts/quests/journeys.yaml`
- `resources/scripts/quests/luoyang_quests.yaml`
- `resources/scripts/quests/dali_quests.yaml`
- `resources/scripts/quests/taihu_quests.yaml`
- `resources/scripts/quests/weiyuan_echoes.yaml`
- `resources/scripts/characters/weiyuan_chapter.yaml`
- `resources/scripts/characters/content_skeleton_npcs.yaml`
- `resources/scripts/characters/kaifeng_jianghu.yaml`
- `resources/scripts/characters/road_encounters.yaml`
- `resources/scripts/characters/regional_and_jianghu_npcs.yaml`
- `resources/scripts/martial_arts/regional_and_jianghu_arts.yaml`
- `resources/scripts/items/regional_and_jianghu_items.yaml`

## 后续制作顺序

1. 给洛阳、大理、太湖在门户信任之后各补一条本地短任务。
2. 扩充开封住宿、买卖、治疗和工作行为。
3. 将北郊递道巡查拆出可重复 job 模板。
4. 等玩家拥有更长经历后，再设计威远旧线的第一次轻微回响。
