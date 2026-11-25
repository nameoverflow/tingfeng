# 听风录（Tingfeng）Pure-Geisha WebAssembly Client

纯 Geisha（自举编译器 `--target wasm32` + 零 libc 独立式分代/分段 Mark-Sweep GC 运行时 `wasm_rt.o`）编译至 WebAssembly 的《听风录》Web 客户端。全界面采用单 Canvas 2D 宋代宣纸牌匾/舆图渲染与水墨矢量骨骼管线，仅保留单个透明原生 `<input>` 代理承载移动端与桌面端中文输入法（IME）合成。

## 架构概览（`client/gsa/src/`）

- `prelude.gsa` & `ordmap.gsa`：复用 `std.control` 高阶类型类（`Functor`、`Applicative`、`Monad`、`MonadState`）与 `Ord` / `Semigroup` / `Monoid` / `MonadWriter`，提供持久化 AVL `OrdMap`/`OrdSet`、UTF-8/CJK 字宽排版与零分配 `StringBuf` 指令流格式化。
- `protocol.gsa`：基于 `std.json` + `std.codec` 的完整网络协议编解码，与服务端 `server/src/message.gsa` 1:1 对齐。
- `i18n.gsa`：中英双语文案词典、武学境界称号与系统/错误消息模板。
- `pose.gsa`、`catalog.gsa`、`battle.gsa`：41 组水墨剪影姿态继承与混合、双骨骼解析逆运动学（2-Bone IK）、`combat_actions/*.json` + `staging.json` 多段伤害拆分、定帧（Hit-Stop）与受击延迟扣血时间轴。
- `state.gsa`：纯函数客户端状态机 `ClientM`（登录与六步创角、区域方向图弹簧相机、NPC 交谈/学艺/行商、角色与行囊、武学修习与自研、任务日志、实时战斗及 `/battle-lab.html` 动作回放台）。
- `uicanvas.gsa` & `render.gsa`：单遍流式 `StringBuf` 全画布渲染指令带构建器（含视口裁剪与 `/pose-sheet.html` 姿态图谱）。
- `mod.gsa` & `spec.gsa`：18 个 `tf_*` WebAssembly 同步导出入口，以及原生肖像/战斗 IK 单元测试套件。
- `public/`：静态宿主页面（`index.html`、`battle-lab.html`、`pose-sheet.html`）、Canvas2D 指令带执行器与低延迟 WebSocket / HTTP 长轮询双通道桥接。

## 构建与运行

确保已安装 Node.js 与自举 Geisha 编译器（自动探测 `$GEISHA`、`../geisha.gsa/build/` 或 `~/code/geisha.gsa/build/`）：

```bash
# 启动后端服务器（仓库根目录）
MUD_DEV_MODE=1 ./server/build/tingfeng-server

# 编译 Geisha -> WebAssembly 并启动客户端服务（默认 http://127.0.0.1:8080）
cd client
npm run build
npm run dev
```

测试入口：
- `http://127.0.0.1:8080/?test=1`：自动连接 `tester` 并重开存档。
- `http://127.0.0.1:8080/battle-lab.html`：纯 Geisha 驱动的剪影交锋动作回放实验室（暴露 `window.__battleLab`）。
- `http://127.0.0.1:8080/pose-sheet.html`：41 组剪影骨骼姿态一览。

## 校验与测试

```bash
npm run check               # 校验全部武学动作数据 + Geisha wasm32 类型检查与 IR 校验
npm run build               # 编译 tingfeng.wasm（~365 KB）并打包至 dist/
npm run test:portraits      # 运行原生 Geisha 肖像哈希/边界与 48 张立绘资产测试
npm run test:battle         # 运行原生 Geisha 战斗解算/2-Bone IK/伤害拆分单元测试
npm run test:battle:browser # 运行 Playwright 端到端浏览器测试套件
```
