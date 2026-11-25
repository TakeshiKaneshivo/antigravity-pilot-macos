# Antigravity Pilot for macOS

<p align="center">
  <img src="icon.png" width="160" alt="Antigravity Pilot icon">
</p>

<p align="center">
  <strong>简体中文</strong> | <a href="README.en.md">English</a>
</p>

专为 macOS 上的 Antigravity 打造的原生领航伴侣：在不打开 Clash TUN 的情况下，让 Antigravity 走本机代理，并提供纯原生的实时上下文监控、模型配额与 Token 用量看板。

**Antigravity Pilot for macOS** 核心特性：

- **兼容 macOS 13.0 (Ventura) 及以上系统**（对齐原版 Antigravity `2.35+` 系统要求），支持 **Universal（Apple Silicon `arm64` + Intel `x86_64`）** 双架构编译、4 语言界面（简体中文 / 繁體中文 / English / Русский）与 `./build.sh --dmg` 一键打包。
- **三通道免 TUN 代理与局域网 CIDR 绕过**：`libantigravity_proxy.dylib`（`__DATA,__interpose` Hook + `NO_PROXY` 域名/私有网段 CIDR 绕过）+ Go/Node 环境变量（含 `NODE_USE_ENV_PROXY=1`）+ 主进程 Chromium `--proxy-server` / `--proxy-bypass-list`。
- **三阶代理健康诊断 & 冲突防护**：实时检测「TCP 端口 → SOCKS5 真实握手 → `generate_204` 出网延迟」，并在启动前自动检测原版与 Pilot 运行冲突，支持一键优雅退出。
- **外置配置 0.1 秒极速热更新 & 动态 Entitlements**：仅修改端口、协议或 `NO_PROXY` 时写入外置 `proxy.env`，跳过重复复制和重签名；首次或重建副本时动态提取并合并原版 `/Applications/Antigravity.app` Entitlements。
- **单层扁平 Runtime 结构与 Dock 单图标秒开**：`AntigravityProxyLauncher` 注入环境后原地 `execv()` 拉起主程序；关闭主窗口后监控缩入右上角菜单栏（`.accessory` 隐藏 Dock 图标），Dock 上依然只保留运行中的 Antigravity Pilot 一个图标。
- **纯原生 SwiftUI 实时监控与用量看板（零 JS 注入、零 CDP）**：
  - 直连本地 `~/.gemini/antigravity/daemon/hub_*.json` Connect-RPC，展示**实时会话上下文构成、TTFT/生成速度、模型共享配额池与重置倒计时**；
  - 增量扫描 `~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl`，通过 SwiftUI `Canvas` 与 `Swift Charts` 绘制 **20 周 Token 活跃热力图、每日趋势与估算 API 账单**；
  - 支持 `NSStatusBar` 菜单栏胶囊 + Popover 与 `SMAppService` 原生登录项自启。
- **Antigravity 应用内看板插件（官方 MCP App）**：
  - 支持在「代理配置」中一键安装/更新/卸载到 `~/.gemini/config/plugins/antigravity-pilot/`，零 JS 注入、原版与代理版通用、自动同步亮暗主题；
  - 在 Antigravity **左侧边栏** 打开「Pilot 监控与账单」全屏看板，或在任意对话右上角 **`+` 菜单** 打开「Pilot 实时监控」辅助面板，直接查看代理三阶健康状态、实时上下文、配额池与近一年（52 周）用量账单。
- **图标切换与完整性同步**：支持在 **默认 Pilot 图标** 与 **原版图标** 之间一键切换（自动刷新 LaunchServices 与 Dock 缓存），并按 Chromium Pickle 4 字节对齐同步 `ElectronAsarIntegrity` 哈希。

---

## 目录

- [项目介绍](#项目介绍)
- [快速开始](#快速开始)
- [图标切换与自定义图标](#图标切换与自定义图标)
- [更新 Antigravity](#更新-antigravity)
- [停止后台进程](#停止后台进程)
- [卸载与清理](#卸载与清理)
- [工作原理](#工作原理)
- [本地构建](#本地构建)
- [本地测试](#本地测试)
- [故障排查](#故障排查)
- [限制](#限制)
- [致谢](#致谢)
- [许可证](#许可证)

---

## 项目介绍

Release 里发布的是一个很轻量的 `Antigravity Pilot.app` 原生伴侣与配置器。它**不包含** Google 原版 `Antigravity.app`。

系统要求与架构支持：

- **macOS 13.0 (Ventura) 及以上**
- **Apple Silicon (`arm64`) 与 Intel (`x86_64`)** Universal 二进制
- **Xcode Command Line Tools**（在生成/刷新本地 Runtime 副本时，系统会调用签名工具执行 ad-hoc 重签名；若尚未安装，可执行 `xcode-select --install`）

配置并启动后，它会：

1. 执行三阶端口健康诊断（TCP 连通 → SOCKS5 握手 → 外网 `generate_204` 延迟探测）。
2. 将配置原子写入外置 `~/Library/Application Support/Antigravity Pilot/proxy.env`。若已存在同版本、同图标且签名一致的 Runtime 副本，**0.1 秒直接热更新拉起**，无需重复复制。
3. 首次生成或需要重建时，从 `/Applications/Antigravity.app` 复制一份单层副本到 `~/Library/Application Support/Antigravity Pilot/Runtime/Antigravity-Pilot.app`，写入 `AntigravityProxyLauncher`、`libantigravity_proxy.dylib`、`proxy.env`，按需替换 `PILOT` 图标与 `app.asar` 并同步 `ElectronAsarIntegrity`，动态合并原版 Entitlements 完成 ad-hoc 重签名。
4. 启动代理版 Antigravity，主窗口可缩入右上角菜单栏常驻监控（支持实时上下文、配额与热力图）；Dock 上只保留这一个运行中的图标，右键「在程序坞中保留」即可日常单图标秒开。

> 原版 `/Applications/Antigravity.app` 不会被修改。

适用场景：

- Antigravity 不读取 macOS system proxy。
- Clash Verge 开启 system proxy 后，Antigravity 仍然无法登录或无法连接。
- 不想长期打开 TUN，只想让 Antigravity 走本机代理，并希望在原生菜单栏随时掌握上下文占用、配额余量与 Token 费用。

---

## 快速开始

### Step 1: 安装原版 Antigravity

请先确认原版 Antigravity 已安装在：

```text
/Applications/Antigravity.app
```

### Step 2: 下载并安装 Antigravity Pilot.app

到本仓库 [Releases](https://github.com/TakeshiKaneshivo/antigravity-pilot-macos/releases) 下载 `Antigravity-Pilot-v0.1.0-macOS13-universal.dmg`（也可参考下方[本地构建](#本地构建)自行编译），打开镜像后将 `Antigravity Pilot.app` 拖入 `Applications` 文件夹。

> **提示**：由于应用目前为本地 ad-hoc 签名、未做 Apple 公证，首次从网上下载打开时如果 macOS 提示“**已损坏，无法打开**”或“**无法验证开发者**”，在终端执行以下命令清除隔离属性后即可正常打开：
>
> ```bash
> xattr -cr "/Applications/Antigravity Pilot.app"
> ```

### Step 3: 打开 Antigravity Pilot，配置端口并启动

打开 `/Applications/Antigravity Pilot.app` 后，左侧边栏提供五个原生页面：**代理概览**、**实时监控**、**用量与账单**、**应用内插件**、**高级设置**。

#### 情况 A：你的 Clash 端口是 7890

如果你使用 Clash Verge 默认 mixed port `7890`：

- 代理 Host：`127.0.0.1`
- SOCKS5 端口：`7890`
- 环境变量协议：`http`
- 环境变量端口：`7890`
- 应用图标：按需选择 **默认 Pilot 图标**（带 `PILOT` 标识，方便与原版区分）或 **原版图标**
- 高级设置：按需调整 `NO_PROXY` 绕过列表（默认放行局域网私有网段 CIDR 与 `*.local`）、菜单栏常驻监控、开机登录自启

点击右下角 **重建副本并启动**（或 **保存并极速启动**）即可。

#### 情况 B：你的 Clash 端口不是 7890

如果你使用的是其他 mixed port，例如 `7893`：

- 代理 Host：`127.0.0.1`
- SOCKS5 端口：`7893`
- 环境变量协议：`http`
- 环境变量端口：`7893`

如果你使用的是独立 SOCKS5 端口，例如 `7891`：

- 代理 Host：`127.0.0.1`
- SOCKS5 端口：`7891`
- 环境变量协议：`socks5`
- 环境变量端口：`7891`

### Step 4: 锁定到 Dock 与菜单栏常驻

1. 代理版 Antigravity 启动后，右键 Dock 上正在运行的图标 → **「选项 → 在程序坞中保留」**（建议将原版 Antigravity 从 Dock 移除，避免日常误点）。
2. Antigravity Pilot 主窗口关闭或启动后会自动缩入右上角菜单栏（Dock 中不留第二个图标），在菜单栏直接显示紧凑指标（如 `188K · 89%`），点击可弹出上下文/配额/今日消耗面板。
3. **何时需要打开主窗口**：查看 20 周 Token 热力图与模型费用账单、修改代理端口/`NO_PROXY`（0.1 秒热更新），或原版 `/Applications/Antigravity.app` 更新后需要刷新副本。

配置保存在 `~/Library/Application Support/Antigravity Pilot/config.json`。

---

## 图标切换与自定义图标

### 在两种内置图标样式间切换

在 `/Applications/Antigravity Pilot.app` 主窗口的 **应用图标** 栏可直接切换：

- **默认 Pilot 图标**：将 Runtime 副本替换成仓库里的带 `PILOT` 标识图标（遵循 macOS HIG 留白规范），方便在 Dock 上区分原版与 Pilot 代理版。
- **原版图标**：保留原版 Antigravity 的扁平锐利 `icon.icns` 与原版 `app.asar`，并移除 `CFBundleIconName`（同时保留磁盘上的 `Assets.car` 以防止 Electron 在运行期覆盖 Dock 图标），在 macOS 13–15 上呈现清晰锐利的原版图标（注意：`/Applications/Antigravity Pilot.app` 伴侣本体始终保持 `PILOT` 图标用于区分）。

### 替换为自己的 PNG 图标

如果你想将默认 Pilot 图标换成完全自定义的图案：

1. 用新的 PNG 图片替换仓库根目录的 `icon.png`（建议遵循 macOS HIG 规范：`1024×1024` 透明底画布，圆角主体居中 `824×824`、四周留白 `100 px`）。
2. 重新构建：

```bash
./build.sh
```

---

## 更新 Antigravity

Antigravity 更新后，不需要重新下载 `Antigravity Pilot.app`。

当原版 `/Applications/Antigravity.app` 更新后，从 Dock 启动 Runtime 副本时会在右上角通知并自动弹出一个 4 秒自动关闭的提醒框，提示原版版本已变化；打开 `/Applications/Antigravity Pilot.app` 主窗口也会在顶部高亮提示重建。

推荐更新流程：

1. 先用原版 `/Applications/Antigravity.app` 完成更新，然后**完全退出** Antigravity。
2. 打开 `/Applications/Antigravity Pilot.app`（或直接利用冲突检测栏一键「退出旧进程并重建」），点击重建副本并启动。
3. 原本固定在 Dock 上的图标位置保持不变，无需重新固定。

---

## 停止后台进程

通常直接从菜单栏或 `Cmd + Q` 退出即可。

如果遇到残留进程，可以在源码目录运行：

```bash
./stop-antigravity-proxy.sh
```

该脚本会同时检查并停止新版 Runtime 进程（`~/Library/Application Support/Antigravity Pilot/Runtime/Antigravity-Pilot.app`）、旧版 `Antigravity Proxy` 进程以及源码目录开发调试副本进程。

---

## 卸载与清理

1. 如已安装应用内看板插件，可先在「应用内插件」页点击 **卸载**（或手动删除 `~/.gemini/config/plugins/antigravity-pilot`）。
2. 完全退出 Antigravity 与菜单栏中的 Antigravity Pilot。
3. 从 Dock 移除保留的代理版图标，并删除 `/Applications/Antigravity Pilot.app`。
4. 删除 Runtime 副本与保存的配置文件（如有旧版目录可一并清理）：

```bash
rm -rf "$HOME/Library/Application Support/Antigravity Pilot"
rm -rf "$HOME/Library/Application Support/Antigravity Proxy"
rm -rf "$HOME/.gemini/config/plugins/antigravity-pilot"
```

原版 `/Applications/Antigravity.app` 不会受到任何影响。

---

## 工作原理

### 为什么不直接注入原版 App

macOS 上的 Google 原版 `/Applications/Antigravity.app` 开启了 **Hardened Runtime（强化运行时）**，且官方签名不包含允许动态库注入的 entitlement（`com.apple.security.cs.allow-dyld-environment-variables`）。系统会直接忽略对原版 App 设置的 `DYLD_INSERT_LIBRARIES`。

因此本项目保持原版不动，在用户本机复制一份单层 Runtime 副本，并动态提取原版 Entitlements 合并注入权限后执行 ad-hoc 重签名。

### 单层结构、三通道拦截与免重建热更新

- **单层扁平 Runtime**：`AntigravityProxyLauncher` 与原版 `Antigravity` 二进制同处于 `Runtime/Antigravity-Pilot.app/Contents/MacOS/`，启动时优先读取外置 `~/Library/Application Support/Antigravity Pilot/proxy.env`（再由 Bundle 内置 `proxy.env` 补齐 `AG_SOURCE_VERSION`），随后原地 **`execv()`** 拉起 `Antigravity` 主程序，PID 与 Bundle 保持同一身份。
- **三通道流量接管**：
  1. **`libantigravity_proxy.dylib`（`__DATA,__interpose`）**：拦截 `getaddrinfo()` / `freeaddrinfo()`（通过拥有指针注册表 `owned_ai_ptrs` 安全分流系统与本库分配节点）与 `connect()`；外网域名分配 `198.18.0.0/15` FakeIP 并通过 SOCKS5 `ATYP=0x03` 域名 `CONNECT` 转发，匹配 `NO_PROXY` 的域名后缀与私网 CIDR 直接直连绕过；
  2. **环境变量注入**：同步导出 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY` 与 `NODE_USE_ENV_PROXY=1`，覆盖 `language_server`（Go）及 Node 22+ 原生请求；
  3. **Chromium 原生参数**：仅针对主 Chromium 进程自动追加 `--proxy-server` 与 `--proxy-bypass-list`（跳过 `ELECTRON_RUN_AS_NODE` 与 `--type=` 子进程）。
- **纯原生监控采集（零入侵）**：
  - 实时上下文与共享配额池：发现 `~/.gemini/antigravity/daemon/hub_*.json` 存活实例后，通过强制禁代理的回环 `URLSession` 调用本地 Connect-RPC（`GetUserStatus`、`GetAllCascadeTrajectories`、`GetCascadeTrajectoryGeneratorMetadata`）；
  - 历史热力图与账单：增量流式扫描 `~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl`，本地缓存于 `usage_cache.json`。

---

## 本地构建

需要 Xcode Command Line Tools：

```bash
xcode-select --install
```

默认直接运行即可编译 **macOS 13.0+ Universal（`arm64` + `x86_64`）** 产物：

```bash
./build.sh
```

如果需要重新编译前端看板并打包可分发的 `.dmg` 安装镜像（同时计算 SHA256）：

```bash
./build.sh --build-web --dmg
```

如需自定义版本号、最低系统版本或目标架构，可以通过环境变量覆盖（默认 `APP_VERSION=0.1.0`、`MIN_MACOS=13.0`、`ARCHS="arm64 x86_64"`）：

```bash
APP_VERSION=0.1.0 MIN_MACOS=14.0 ARCHS=arm64 ./build.sh --dmg
```

构建产物：

```text
build/Antigravity Pilot.app
build/Antigravity-Pilot-v0.1.0-macOS13-universal.dmg   # 传入 --dmg 时生成
build/antigravity-pilot-mcp
build/libantigravity_proxy.dylib
build/AntigravityProxyLauncher
build/test_client
```

也支持直接对构建好的二进制运行非 UI 原生冒烟校验：

```bash
"build/Antigravity Pilot.app/Contents/MacOS/AntigravityProxyBuilder" --smoke-test
```

---

## 本地测试

验证 FakeIP 分配、SOCKS5 `CONNECT` 与 `NO_PROXY` 绕过：

```bash
./build.sh
./tests/socks5_capture.py 18081
```

另开一个终端：

```bash
AG_PROXY=socks5://127.0.0.1:18081 \
AG_PROXY_LOG=1 \
DYLD_INSERT_LIBRARIES="$PWD/build/libantigravity_proxy.dylib" \
./build/test_client login.example.test 443
```

成功时，SOCKS5 测试服务会输出：

```text
captured login.example.test:443
```

---

## 故障排查

### 提示“已损坏，无法打开”或“无法验证开发者”

```bash
xattr -cr "/Applications/Antigravity Pilot.app"
```

### 点击重建时提示需要安装 Xcode 命令行开发者工具

```bash
xcode-select --install
```

### 诊断胶囊提示「非 SOCKS5 端口」或「外网未通」

- 若提示 **非 SOCKS5 端口**：说明所填端口是纯 HTTP 端口而非 SOCKS5 / 混合端口，请检查 Clash Verge 的 Mixed Port（默认 `7890`）或独立 SOCKS5 端口。
- 若提示 **外网未通**：说明本机代理端口可达，但代理节点无法访问 `www.google.com/generate_204`，请检查代理客户端节点与出站规则。

### 切换为「原版图标」或「默认 Pilot 图标」后 Dock 图标没变化

- 切换图标会自动刷新 LaunchServices 并重启 Dock。
- 随开关变化的是 **Runtime 副本**（`~/Library/Application Support/Antigravity Pilot/Runtime/Antigravity-Pilot.app`），`/Applications/Antigravity Pilot.app` 本身始终保持 `PILOT` 图标。
- 极少数情况缓存残留时，可在完全退出 Antigravity 后执行 `killall Dock`。

### 启动后显示空白的 Electron 欢迎页（提示 `To run a local app...`）

请在退出后打开 `/Applications/Antigravity Pilot.app`，在「高级设置」点击 **强制完整重建副本**，重新按 Chromium Pickle 4 字节对齐同步 `ElectronAsarIntegrity` 即可。

### 原版 Antigravity 打不开

不要同时运行原版和 Pilot 代理版（共用同一个用户数据目录和单实例锁）。在 Pilot 主窗口顶部冲突提示栏直接点击 **优雅退出并启动** 即可自动完成切换。

---

## 限制

- dylib hook 只处理 TCP `connect()`，不处理 UDP/QUIC，且目前仅支持无认证 SOCKS5 代理。
- 代理地址建议使用数字 IP，例如 `127.0.0.1`。
- 生成/首次重建 Runtime 副本需要复制完整 Antigravity，会等待几秒钟；此后仅修改端口/协议/绕过列表支持 0.1 秒免重建热更新，日常从 Dock 启动可秒开。
- 历史费用账单基于内置公开 API 参考定价表估算（支持在 `~/Library/Application Support/Antigravity Pilot/custom_pricing.json` 自定义覆写），不代表实际订阅扣费。
- `Antigravity Pilot.app` 目前为 ad-hoc 签名；公开分发时建议进一步做 Developer ID 签名和 notarization。

---

## 致谢

- [OkamiFeng/mac-antigravity-proxy-dylib](https://github.com/OkamiFeng/mac-antigravity-proxy-dylib)：本项目最初基于该项目的早期版本演进与重构而来，感谢原作者在 macOS dylib 代理注入与签名流程上的开创性工作。
- [yuaotian/antigravity-proxy](https://github.com/yuaotian/antigravity-proxy)：感谢 Windows 版本的 DLL 注入代理拦截思路启发（本项目在 macOS 上采用 `DYLD_INSERT_LIBRARIES` 注入 dylib 实现）。

---

## 许可证

MIT License。详见 [LICENSE](LICENSE)。
