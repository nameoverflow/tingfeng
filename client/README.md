# 听风录（Tingfeng）Pure Haskell WebAssembly Client

纯 Haskell（GHC 9.10 `wasm32-wasi` + JSFFI）编译至 WebAssembly 的《听风录》Web 客户端，底层采用单 WebGL2 水墨宣纸/冲击波着色器 + Canvas 2D 矢量骨骼管线，上层保留极薄响应式 HTML/IME 层承载中文排版、移动端五栏导航与键盘无障碍操作。

## 架构概览

- `hs/src/Tingfeng/Json.hs`：零外部依赖的纯 Haskell RFC 8259 JSON 解析与构建器。
- `hs/src/Tingfeng/Protocol.hs`：与服务端 `src/Game/Message.hs` 1:1 对齐的完整网络协议编解码。
- `hs/src/Tingfeng/I18n.hs`：中英双语文案词典、武学境界称号与系统/错误消息模板。
- `hs/src/Tingfeng/Pose.hs` & `Catalog.hs` & `Battle.hs`：41 组水墨剪影姿态解析、双骨骼解析逆运动学（2-Bone IK）、`combat_actions/*.json` + `staging.json` 多段伤害拆分、定帧（Hit-Stop）与受击延迟扣血时间轴。
- `hs/src/Tingfeng/State.hs`：客户端纯函数状态机（登录与六步创角、区域方向图弹簧相机、NPC 交谈/学艺/行商、角色与行囊、武学修习与自研、任务日志、实时战斗及 `/battle-lab.html` 动作回放台）。
- `hs/src/Tingfeng/Render.hs`：单帧零 DOM 抖动渲染指令带构建器（含视口裁剪与姿态图谱）。
- `hs/src/Main.hs`：GHC 9.10 `wasm32-wasi` JSFFI 导出入口。
- `public/`：静态宿主页面（`index.html`、`battle-lab.html`、`pose-sheet.html`）、WebGL2/Canvas2D 执行器与低延迟 WebSocket / HTTP 长轮询双通道桥接。

## 构建与运行

确保已安装 Node.js 与 `ghc-wasm-meta`（GHC 9.10 `wasm32-wasi` 工具链，默认自动探测 `../ghc-wasm/env` 或 `$GHC_WASM_ENV`）：

```bash
# 启动后端服务器
MUD_DEV_MODE=1 stack exec tingfeng-exe

# 编译 Haskell -> WebAssembly 并启动客户端服务（默认 http://127.0.0.1:8080）
cd client
npm run build
npm run dev
```

测试入口：
- `http://127.0.0.1:8080/?test=1`：自动连接 `tester` 并重开存档。
- `http://127.0.0.1:8080/battle-lab.html`：纯 Haskell 驱动的剪影交锋动作回放实验室（暴露 `window.__battleLab`）。
- `http://127.0.0.1:8080/pose-sheet.html`：41 组剪影骨骼姿态一览。

## 校验与测试

```bash
npm run check               # 校验全部武学动作数据 + GHC -Wall -Werror 类型检查
npm run build               # 编译 tingfeng-hs.wasm 并打包至 dist/
npm run test:battle         # 运行原生 GHC 战斗解算/IK/伤害拆分单元测试
npm run test:battle:browser # 运行 Playwright 端到端浏览器测试套件
```
