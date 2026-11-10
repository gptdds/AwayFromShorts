# AwayFromShorts Tauri Shell

Tauri 2.0 thin shell wrapper. 把"浏览器开 127.0.0.1:8737"体验变成原生桌面窗口 + 系统托盘。

---

# ⚠️ 必读：两条安全红线

> 这两条来自一次真实事故。2026-11-10，为验证「非管理员启动卸载」的行为，
> 在**有正式安装的开发机**上跑了不带 `-DryRun` 的 `nsis-uninstall.ps1 -Cleanup`，
> 结果 UAC 被自动批准、脚本真的删掉了全部 4 个计划任务并停掉了面板。
> 已用项目自带注册脚本完整恢复，但代价是本可完全避免的。

## 红线一：破坏性验证必须在隔离环境

- **有真实安装的机器上，禁止运行任何非 dryrun 的 `-Cleanup` / 卸载 / 安装分支。**
  清理脚本删计划任务、停进程、恢复 hosts 都是**全局动作，不区分 `-AppDir`**——
  把 `-AppDir` 指到模拟目录并不能隔离这些副作用。
- 要验证提权、卸载、安装的真实行为，只能在 **VM / 一次性沙盒**里做。
  本机只允许 `-DryRun`，或只读的 `-CheckOnly`。
- **`-Cleanup` 与 `-DryRun` 必须正交，且 `-DryRun` 必须覆盖全部全局副作用**：
  删计划任务、停进程、写 hosts 这三件事在 dryrun 下只能「打印将要执行什么」，
  绝不执行。当前 `scripts/nsis-install.ps1` 与 `nsis-uninstall.ps1` 已满足此要求
  （`-DryRun` 时这三类动作全部输出 `DRYRUN-SKIP` 并跳过）；但**开关再完备也挡不住
  有人故意不带它**——纪律才是最后一道防线。
- **本机 UAC 会自动批准，等于没有安全网。** 不要指望「弹 UAC 会挡住自动化」：
  `Start-Process -Verb RunAs` 在这台机器上静默提权成功，脚本随即以管理员执行了
  真实清理。任何依赖「UAC 会中断」的假设都不成立。
- 事故后恢复时也要克制：注册好任务后**不要手动触发引擎**，让每分钟触发器自行运行；
  否则在强制模式屏蔽时段内会立即写 hosts / 杀进程，扩大影响面。

## 红线二：`hosts.backup` 为空的上游缺陷（非本次事故造成）

现状（只读核实）：

```
%LOCALAPPDATA%\AwayFromShorts\hosts.backup
  size     : 8 bytes
  modified : 2026/8/22 11:48:48   ← 安装当天就是这个样子，不是这次事故写的
  hex      : 0d 0a 0d 0a 0d 0a 0d 0a   ← 只有 4 个空行
```

**后果**：卸载/恢复 hosts 时若直接用它覆盖，会把用户自定义条目清空。
本次事故后的 hosts 里 Docker Desktop、Tailscale 等段落是靠各自服务重新写回才补回来的；
如果用户原本有手工添加的条目，那样一次覆盖就真的丢了。

**建议在上游修**（本项目未改，属 PowerShell 侧逻辑）：

1. 备份时写入「当前 hosts 去掉 AFS 标记块后的干净内容」，而不是原样复制一个可能为空的文件。
2. 恢复前校验 backup：若为空白 / 仅空行，则**拒绝覆盖并记日志**，宁可保留现状也不清空。

在修好之前，卸载或任何 hosts 恢复动作都应先人工确认 backup 内容非空。

---

## 原理

- Tauri 窗口直接加载 `http://127.0.0.1:8737`（webui.ps1 的 HTTP 服务）
- 前端 HTML / PowerShell 代码一行不改
- 启动时自动检测面板是否在跑；不在跑就通过计划任务或直接启动 webui.ps1
- 系统托盘：左键单击切换窗口显隐，右键菜单（显示面板 / 隐藏到托盘 / 退出）
- 关闭按钮 → 隐藏到托盘（release 模式），不退出进程

## 目录结构

```
tauri-shell/
├── README.md               # 本文档
├── run-dev.bat             # 开发态启动脚本（绕过中文路径问题, 见下）
├── scripts/
│   ├── prepare-bundle.ps1      # 打包前生成干净运行文件（排除用户数据）
│   ├── nsis-install.ps1        # 安装阶段编排（复用现有注册脚本, 支持 -DryRun）
│   └── nsis-uninstall.ps1      # 卸载阶段编排（保留强制模式守卫, 支持 -DryRun）
└── src-tauri/
    ├── Cargo.toml          # Rust 依赖
    ├── build.rs            # tauri-build
    ├── tauri.conf.json     # Tauri 配置（窗口 URL、托盘、打包、NSIS hooks）
    ├── src/
    │   └── main.rs         # Rust 端：窗口 + 托盘 + 面板检测 + --autostart
    ├── nsis/
    │   ├── installer.nsi           # 官方模板副本（仅改 RequestExecutionLevel）
    │   ├── installer-hooks.nsh     # 4 个 NSIS hook 宏
    │   ├── PATCH.md                # 模板改动与上游版本记录
    │   └── check-template-drift.ps1 # 升级 Tauri 后的模板漂移自检
    ├── bundle-resources/   # prepare-bundle.ps1 生成，随包携带（不入库）
    └── icons/             # 应用图标（PNG + ICO）
```

## 构建

```powershell
cd tauri-shell\src-tauri

# 只编译 exe（不打包安装器）
cargo build --release

# 编译并打包 NSIS 安装器
cargo tauri build
```

构建产物：
- exe: `src-tauri\target\release\awayfromshorts-shell.exe`（约 12 MB）
- 安装器: `src-tauri\target\release\bundle\nsis\AwayFromShorts_2.0.0_x64-setup.exe`

## 运行

**正式使用：运行 NSIS 安装器** `AwayFromShorts_2.0.0_x64-setup.exe`，它会把 exe 装到
`%LOCALAPPDATA%\AwayFromShorts`（纯 ASCII 路径），装完双击桌面/开始菜单快捷方式即可。

```powershell
# 或在安装目录直接运行
%LOCALAPPDATA%\AwayFromShorts\awayfromshorts-shell.exe
```

前提：webui.ps1 已在运行（计划任务开机自启，或手动运行 start-web.bat）。如果没在跑，app 会自动尝试启动它。

### ⚠️ 中文路径坑（重要）

本项目根目录含中文「空间」。**WebView2 Runtime 在 exe 位于含非 ASCII 字符的路径时无法初始化**
（报错 `拒绝访问 (os error 5)` 或 `0x8000FFFF 灾难性故障`），窗口起不来。这是 WebView2/Windows 层的限制，
与 Tauri 代码无关 —— 已验证：把同一个 exe 复制到 `C:\afs-tauri-test\` 纯 ASCII 路径即可正常运行,
窗口完整渲染出 127.0.0.1:8737 的面板（含菜单、统计页、深色主题）。

- **正式安装不受影响**：NSIS 装到 `%LOCALAPPDATA%\AwayFromShorts`，纯 ASCII。
- **在中文源码目录里直接双击 `target\release\awayfromshorts-shell.exe` 会失败**。调试时用
  `run-dev.bat`：它会把 exe 复制到 `%LOCALAPPDATA%\AwayFromShorts\shell`（纯 ASCII）再启动。
- 已排除的错误方向：数据目录重定向（`WEBVIEW2_USER_DATA_FOLDER`）、8.3 短路径（该卷未生成短名）均无效,
  根因是 WebView2 loader 读取 exe 自身路径, 只能靠 exe 放在 ASCII 路径解决。

## 系统托盘

| 操作 | 效果 |
|------|------|
| 关闭按钮 | 隐藏到托盘，进程不退出 |
| 托盘左键单击 | 切换窗口显示/隐藏 |
| 托盘右键 → 显示面板 | 显示窗口 |
| 托盘右键 → 隐藏到托盘 | 隐藏窗口 |
| 托盘右键 → 退出 | 退出程序 |

## IPC 命令（可选，供前端调用）

前端可以通过 Tauri IPC 调用以下命令（目前前端不需要，因为直接走 HTTP API）：

```javascript
// 检查面板是否在运行
const running = await window.__TAURI__.core.invoke('check_panel');

// 启动面板
const ok = await window.__TAURI__.core.invoke('start_panel');
```

## 注意

- 不动任何现有 PowerShell 代码（core.ps1 / webui.ps1 / install 脚本）；NSIS 编排只复用它们
- Tauri 壳是额外的一层，不是替换
- WebView2 Runtime 是前提（Windows 10/11 通常自带；Edge 安装目录下有 156.x / 157.x 版本）
- NSIS 安装器已整合原 install.bat 的安装流程（管理员权限 / hosts 备份 / 计划任务 / 开机自启 /
  立即执行 / 拉起面板 / 卸载清理），并新增 `AwayFromShorts-Shell` 托盘自启任务（`--autostart` 隐藏窗口）
- 模板副本仅改一行 `RequestExecutionLevel`；升级 Tauri 前先跑 `nsis/check-template-drift.ps1`
- **验证纪律见文首「必读：两条安全红线」**
