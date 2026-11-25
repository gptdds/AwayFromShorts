/* ============================================================
 *  AwayFromShorts - 前端回归自检 (无需浏览器)
 *  用法: node tools/verify-frontend.js
 *  作用:
 *    1) 解析 src/web/index.html 内所有 <script> 块做语法检查 (vm.Script)
 *    2) 检查关键功能标记是否还在 (防回退)
 *    3) 检查 CSS 括号平衡 / HTML 关键标签配对
 *  退出码: 0 = 全部通过, 1 = 有失败项
 * ============================================================ */
const fs = require("fs");
const vm = require("vm");
const path = require("path");

const file = path.join(__dirname, "..", "src", "web", "index.html");
const html = fs.readFileSync(file, "utf8");
let bad = 0;
function rep(label, ok, extra) {
  console.log((ok ? "OK  " : "FAIL") + " " + label + (extra ? " " + extra : ""));
  if (!ok) bad++;
}

/* ---------- 1. 脚本语法 ---------- */
const blocks = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
if (!blocks.length) rep("存在 <script> 块", false);
blocks.forEach((code, i) => {
  try { new vm.Script(code, { filename: "block" + i + ".js" }); rep("script#" + i + " 语法", true, "(" + code.length + " chars)"); }
  catch (e) { rep("script#" + i + " 语法", false, "- " + e.message); }
});

/* ---------- 2. 功能标记 ---------- */
const markers = [
  ["请求超时常量 API_TIMEOUT", /const API_TIMEOUT = 15000;/],
  ["只读请求自动重试", /_attempt < 1/],
  ["保存按钮 finally 恢复(含文案)", /finally \{ btn\.disabled = false; btn\.textContent = oldTxt; \}/],
  ["原生控件跟随主题 color-scheme", /color-scheme: light;/],
  /* ---- bilibili 中文门户风格 (来源: UI知识库 design-specs/design-spec-bilibili.md, A 级证据) ---- */
  ["bilibili: 页面底 Ga1 #F1F2F3", /--bg: #f1f2f3;/],
  ["bilibili: 卡片面白 #FFFFFF", /--surface: #ffffff;/],
  ["bilibili: 主文字 Ga10 #18191C", /--text-primary: #18191c;/],
  ["bilibili: 次文字 Ga7 #61666D", /--text-secondary: #61666d;/],
  ["bilibili: 品牌蓝 #00AEEC (主行动色)", /--brand: #00aeec;/],
  ["bilibili: 品牌粉 #FF6699 (次要强调)", /--brand-pink: #ff6699;/],
  ["bilibili: 三档线 line_regular #E3E5E7", /--border: #e3e5e7;/],
  ["bilibili: 三档线 line_bold #C9CCD0", /--border-hover: #c9ccd0;/],
  ["bilibili: 圆角基准 6px", /--radius: 6px;/],
  ["bilibili: 无胶囊(radius-pill 收到 6px)", /--radius-pill: 6px;/],
  ["bilibili: 零投影分层(靠三档线)", /--sh-1: none;/],
  ["bilibili: 仅浮层保留投影", /--shadow: 0 4px 12px rgba\(0,0,0,\.08\);/],
  ["bilibili: 过渡统一 150ms", /transition: background \.15s, border-color \.15s, color \.15s;/],
  ["bilibili: 选中色为品牌蓝", /::selection \{ background: rgba\(0,174,236,\.22\); \}/],
  ["bilibili: 语义色 success_green", /--green: #2ac864;/],
  ["bilibili: 语义色 stress_red", /--red: #f85a54;/],
  ["bilibili: 语义色 operate_orange", /--orange: #ff7f24;/],
  ["bilibili: 大标题 24px/500/normal 字距", /\.topbar h1 \{[\s\S]{0,160}font-size: 24px; line-height: 1\.5; font-weight: 500;/],
  ["bilibili: 中文优先字族", /"PingFang SC",\s*\n?\s*"HarmonyOS_Regular"/],
  ["外观切换: 预设防闪脚本", /localStorage\.getItem\("afs-theme"\)/],
  ["外观切换: 顶栏按钮", /id="themeBtn"/],
  ["外观切换: 选择持久化", /localStorage\.setItem\(THEME_KEY, themeMode\)/],
  ["外观切换: 白底深字导航", /--nav-l: 38%;/],
  /* ---- b 站深夜模式 (html[data-theme="dark"]) ---- */
  ["深夜模式: 暗色底 #17181A", /--bg: #17181a;/],
  ["深夜模式: 暗色卡片面 #242528", /--surface: #242528;/],
  ["深夜模式: 亮档主文字", /--text-primary: #e3e5e7;/],
  ["深夜模式: 暗色三档线", /--border: #3d3f42;/],
  ["深夜模式: 阴影加深", /--shadow: 0 4px 12px rgba\(0,0,0,\.4\);/],
  ["深夜模式: 亮档导航文字", /--nav-l: 68%;/],
  ["深夜模式: color-scheme dark", /color-scheme: dark;/],
  ["昼夜自动: 三档模式", /const THEME_MODES = \["auto", "light", "dark"\];/],
  ["昼夜自动: 昼夜分界常量", /const AFS_DAY_FROM = 7;[\s\S]{0,80}const AFS_DAY_TO   = 19;/],
  ["昼夜自动: 按小时判定", /return h >= AFS_DAY_FROM && h < AFS_DAY_TO;/],
  ["昼夜自动: 定时校准+回页面校准", /setInterval\(syncAutoTheme, 30000\)[\s\S]{0,200}visibilitychange", syncAutoTheme/],
  ["昼夜自动: 预设脚本自带昼夜判定", /window\.__afsThemeMode = mode;/],
  ["昼夜自动: 旧的固定选择只迁移一次", /afs-theme-mig/],
  ["卸载守卫: 锁定提示条", /id="uninstallLockNote"/],
  ["卸载守卫: 状态驱动禁用按钮", /btn\.disabled = blocked;/],
  ["卸载守卫: 点击二次守卫", /if \(status && status\.uninstallBlocked\)/],
  ["卸载守卫: 手动卸载说明随锁定改文案", /id="uninstallManualNote"/],
  ["卸载守卫: 随状态/轮询刷新", /renderTop\(\); renderHome\(\); renderStatus\(\); renderFreeze\(\); renderUninstallGuard\(\);/],
  ["全局滚动: 外壳不再锁死高度", /\.app \{ display: flex; min-height: 100vh; \}/],
  ["全局滚动: 侧边栏 sticky", /position: sticky; top: 0; height: 100vh/],
  ["自动刷新周期 20s", /const AUTO_REFRESH_MS = 20000;/],
  ["自动刷新挂载", /setInterval\(autoRefresh, AUTO_REFRESH_MS\);/],
  ["后台暂停刷新", /if \(autoBusy \|\| document\.hidden\) return;/],
  ["切回前台补刷", /visibilitychange/],
  ["静默刷新 refreshStatus(silent)", /async function refreshStatus\(silent\)/],
  ["静默刷新 refreshStats(silent)", /async function refreshStats\(silent, forceActivity\)/],
  // 统计页: activity(应用使用) 必须跟着刷新, 否则「每日/周/月」三个视图永远停在首屏数据
  ["统计: 刷新同时拉 activity", /async function refreshActivity\(silent\)/],
  ["统计: 刷新统计并发拉两条数据源", /Promise\.allSettled\(needAct \? \[api\("\/api\/stats"\), api\("\/api\/activity"\)\]/],
  ["统计: 渲染与请求失败分离", /function safeRenderStats\(\)/],
  ["统计: 界面显示刷新时间", /已更新 " \+ statsStamp\(\)/],
  ["统计: 连接类失败静默退避重试", /function statsScheduleRetry\(\)/],
  ["统计: 刷新状态行存在", /id="statsUpdated"/],
  ["统计: 视图切换补拉 activity", /if \(statsNeedsActivity\(\) && Date\.now\(\) - actLast > 20000\)/],
  ["统计: 首屏先落 activity 再渲染", /activity = act\.value\.activity; actLast = Date\.now\(\);\s*\}\s*if \(st\.status === "fulfilled" && st\.value\) stats = st\.value\.stats;/],
  ["断线提示", /面板无响应/],
  // v1.4.0 优化: 稳定性/性能守卫
  ["倒计时后台暂停", /if \(!homeCountdown \|\| document\.hidden\) return;/],
  ["状态操作防连点 actBusy", /let actBusy = false;/],
  ["状态操作不强制拉 activity", /Promise\.all\(\[refreshStatus\(\), refreshStats\(true\)\]\)/],
  ["队列落地不覆盖未保存编辑", /if \(dirty\) \{\s*\/\/ 表单里有未保存的编辑/],
  ["统计重试后台/离页即停", /if \(document\.hidden \|\| !panelActive\) \{ statsAttempt = 0; return; \}/],
  ["手动重连取消排队重试", /clearTimeout\(bootTimer\); bootTimer = null; bootAttempt = 0;/],
  ["ensureBrowser 兜底函数", /function ensureBrowser\(\)/],
  ["空时段诚实空状态(不伪造 19:00)", /id="windowEmpty"/],
  ["空时段走三元分支而非回写配置", /\$\("#windowRows"\)\.innerHTML = ws\.length \? ws\.map/],
  ["减少动效降级", /@media \(prefers-reduced-motion: reduce\)/],
  ["侧边栏 <nav> 语义", /<nav class="sidebar" aria-label="主导航">/],
  ["role=tablist", /role="tablist" aria-orientation="vertical"/],
  ["toast aria-live", /role="status" aria-live="polite" aria-atomic="true"/],
  ["activateTab 切换函数", /function activateTab\(el\)/],
  ["方向键导航", /e\.key === "ArrowDown" \|\| e\.key === "ArrowRight"/],
  ["aria-selected 同步", /setAttribute\("aria-selected", on \? "true" : "false"\)/],
  ["可见焦点环", /:focus-visible \{ outline: 2px solid var\(--accent\)/],
  ["按钮样式复位", /width: 100%; background: transparent; font: inherit; text-align: left;/],
  ["强制模式: 星期/时段锁定", /forceLocked/],
  // 强制模式开启期间: 「屏蔽网页 / 屏蔽进程 / 白名单」改为排队(非屏蔽时段自动生效);
  // 「屏蔽星期 / 屏蔽时段」与「从云端拉取配置」仍是硬锁。
  ["排队: 补丁深合并(不丢嵌套键)", /function deepMergePatch\(target, patch\)/],
  ["排队: 叠加到展示态", /function applyPendingToView\(p\)/],
  ["排队: 状态变量 pendingInfo", /let pendingInfo = null;/],
  ["排队: 顶栏待生效胶囊", /id="pendingPill"/],
  ["排队: 黄色提示条样式", /\.queue-note \{/],
  ["排队: 按类目取排队条目", /function pendingItemsFor\(sel\)/],
  ["排队: 撤销排队按钮", /class="btn small pending-clear"/],
  ["排队: 撤销走 /api/pending/clear", /"\/api\/pending\/clear", "POST", \{\}/],
  ["排队: 保存后按 queued 区分提示", /if \(r\.queued\) toast\("⏳ 已排队/],
  ["排队: 队列变化后重新拉配置", /if \(qBefore !== qAfter\)/],
  ["强制模式: 锁定提示 helper", /function applyLockNote\(/],
  ["强制模式: 禁用+整行变灰 helper", /function setLocked\(/],
  ["强制模式: 硬锁行整行变灰", /row\.classList\.toggle\("locked", !!locked\)/],
  ["强制模式: 屏蔽网页提示位", /id="sitesLockNote"/],
  ["强制模式: 时段名单提示位", /id="freezeWindowLockNote"/],
  ["强制模式: 白名单提示位", /id="wlLockNote"/],
  ["强制模式: 同步拉取硬锁提示位", /id="syncLockNote"/],
  ["强制模式: 渲染时调用提示", /applyLockNote\("#sitesLockNote", locked,/],
  ["强制模式: 云端拉取硬锁 toast", /「从云端拉取配置」不可用/],
  // 强制模式开启期间「只能增不能删」: 收紧方向可保存, 放宽方向直接拒绝
  ["收紧: tightenOnly 开关", /const tightenOnly = \(\) => forceLocked\(\);/],
  ["收紧: 放宽提示 helper", /function tightenToast\(what, why\)/],
  ["收紧: 时段名单字段表", /const WINDOW_LIST_FIELDS = \{/],
  ["收紧: 删除按钮按 locked 禁用", /data-window-del="\$\{field\}"[\s\S]{0,140}\$\{locked \? 'disabled title="强制模式开启中，删除时段名单等于放宽，已锁定"/],
  ["收紧: 删除事件二次守卫", /if \(forceLocked\(\)\) \{[\s\S]{0,140}tightenToast\("「时段专属名单」", "删掉一条就等于放行一点"\)/],
  ["收紧: 时段预设取消勾选拦截", /if \(forceLocked\(\)\) \{[\s\S]{0,140}tightenToast\("「当前时段名单」", "取消已选预设等于删掉这些条目"\)/],
  ["收紧: 白名单新增拦截", /tightenToast\(kind === "wlsite" \? "「白名单域名」" : "「白名单进程」", "加入白名单等于变相放行"\)/],
  ["收紧: 白名单输入框禁用", /setLocked\("#addWlSiteBtn", ro\)/],
  ["收紧: 总开关开关不能关", /if \(tightenOnly\(\) && !e\.target\.checked\)/],
  ["收紧: 工作区/网址拦截开关不能关", /tightenToast\("「网址拦截」开关"/],
  ["收紧: 卡片琥珀色受限边框", /\.preset\.tighten \{ border-color: rgba\(255,176,32,\.3\); \}/],
  ["收紧: 提示条按方向措辞", /const rule = "只能新增, 不能删减";/],
  ["收紧: 强制卡片同步说明", /只能收紧不能放宽/],
  // 首屏健壮性 (开机后空白页回归防护)
  ["首屏分接口结算 allSettled", /Promise\.allSettled\(/],
  ["首屏退避重试 bootRetry", /function bootRetry\(/],
  ["启动即触发重试", /bootRetry\(\);/],
  ["自动刷新兜底加载", /if \(!status \|\| !cfg\) \{ await load\(\); return; \}/],
  ["状态胶囊可点击重连", /topPillEl\.addEventListener\("click"/],
  ["渲染前校验核心数据", /if \(cfg && status\) \{ renderHome\(\); renderStatus\(\); renderFreeze\(\); \}/],
  ["连接中提示", /正在连接面板/],
  // 视觉分层: bilibili 靠三档线 + 三级底色, 噪波/光斑属反 AI 味花活已整体移除
  ["分层: 三档线走令牌", /border: 1px solid var\(--border\);/],
  ["分层: 卡片底走 --surface", /\.card:hover \{ border-color: var\(--border-hover\); background: var\(--surface\); \}/],
  ["动效: 切页入场 playPanelEnter", /function playPanelEnter/],
  ["动效: 入场用 backwards(不挡 hover)", /panelIn \.25s ease-out backwards/],
  ["动效: 列表插入 rowIn", /@keyframes rowIn/],
  ["动效: 柱条数值过渡", /\.bar-fill, \.vb \.bar \.col/],
  ["减少动效降级保留", /@media \(prefers-reduced-motion: reduce\)/],
  // 切页: 已从「光柱/扫光/色相」整体收敛为纯淡入(spec §9 禁止渐变与发光)
  ["动效: 只保留标题淡入 titleIn", /@keyframes titleIn/],
  ["动效: 切页竞态防护", /if \(token !== tabSwapToken\) return;/],
  // bilibili 风格落地时的「继承可见性」检查: 这些 pattern 出现在源码里就说明有残留
  ["检查: 无渐变(linear-gradient)", /linear-gradient/, true],
  ["检查: 无渐变(radial-gradient)", /radial-gradient/, true],
  ["检查: 无玻璃拟态", /backdrop-filter/, true],
  ["检查: 无花活光柱 DOM", /id="navGlow"/, true],
  ["检查: 无扫光动画", /@keyframes warpSweep/, true],
  ["检查: 无色相令牌", /--tab-h/, true],
  ["检查: 无冲击环", /@keyframes navBurst/, true],
  ["检查: 无扫描光", /@keyframes scanDown/, true],
  ["检查: 无交替飞入", /@keyframes panelInAlt/, true],
  ["检查: 无硬编码旧辅色", /#eab308|#facc15|#f59e0b/, true],
  ["检查: 无 hover 位移上浮", /transform: translateY\(-\d+px\) scale/, true],
  ["检查: 无光晕式扩散阴影", /box-shadow:\s*0 0 \d+px (?!inset)/, true],
  ["检查: 无噪波颗粒层", /--noise|mix-blend-mode/, true],
  ["检查: 无鼠标跟随光斑", /--mx: 50%/, true],
  ["检查: 无弹跳曲线", /cubic-bezier\(\.34,\s*1\.56/, true],
  ["检查: 无胶囊圆角 9999px", /9999px/, true],
  ["检查: 无 Linear 色残留", /#5e6ad2|#08090a|#8a8f98|#0f1011/, true],
  // 站点项路径支持: "域名" 或 "域名/路径" (整站屏蔽 + 路径放行)
  ["路径: 屏蔽输入框提示含路径示例", /placeholder: "例如: example\.com 或 www\.bilibili\.com\/video\/\*"/],
  ["路径: 白名单输入框提示含路径示例", /placeholder="例如: mail\.example\.com 或 www\.bilibili\.com\/video\/\*"/],
  ["路径: 白名单说明区分整站与路径", /只放行该路径, 同域名的其他页面仍按屏蔽表处置/],
  ["路径: 添加时保留尾缀通配", /if \(v\.endsWith\("\/\*"\)\)/],
  ["路径: 校验提示含路径写法", /需为域名，或「域名\/路径」/],
  ["信息架构: 时间限额一级入口", /data-tab="quota"[^>]*>[\s\S]{0,80}时间限额/],
  ["信息架构: 时间限额独立面板", /id="panel-quota"/],
  ["信息架构: 网站与冻结应用并入冻结时段", /class="window-scope-grid"/],
  ["信息架构: 时段名单计数取并集", /function windowUnionCount\(field\)/],
  ["排列: 按列 / 堆积切换", /id="freezeLayoutToggle"/],
  ["排列: 窗口按列布局", /#windowRows\.layout-columns/],
  ["排列: 名单堆积布局", /#windowRows\.layout-stack \.window-scope-grid/],
  ["排列: 布局偏好持久化", /FREEZE_LAYOUT_KEY/],
  ["信息架构: 网站屏蔽独立页已移除", /id="panel-sites"/, true],
  ["信息架构: 冻结应用独立页已移除", /id="panel-processes"/, true],
  ["限额星期: 七个星期选项", /const QUOTA_WEEKDAYS = \["一","二","三","四","五","六","日"\];/],
  ["限额星期: 旧数据默认七天", /return days\.length \? \[\.\.\.new Set\(days\)\]\.sort/],
  ["限额星期: 至少保留一天", /每条限额规则至少保留一个生效星期/],
  ["限额星期: 今日未启用不累计", /今天未启用，不累计、不冻结/],
  ["限额星期: 自定义应用与共享格复用", /id="quotaProcessName"[\s\S]{0,260}id="quotaAddApp"/],
  ["限额开关: 规定时间外也可关闭", /时间限额开关可随时关闭/],
  ["限额开关: 不再按修改时段禁用", /quotaToggle\.disabled = overviewToggle\.disabled = false;/],
  ["限额编辑: 总开关或限额关闭时解锁", /editUnlocked\s*\?[\s\S]{0,160}可以自由调整应用/],
  ["限额编辑: 复用统一调整时段", /quotaWindowLabel = editWindow\?\.label \|\| '调整时段'/],
  ["限额编辑: 不再写死 21 点", /每天 21:00–21:59/, true],
  ["限额保存: 顶部保存合并未提交限额", /hadQuotaChanges\s*&&[\s\S]{0,120}saveQuotaSettings\(\{ quiet: true \}\)/],
  ["学习联动: 开关可随时关闭", /学习联动是独立开关[\s\S]{0,120}sw\.disabled = false;/],
  ["学习联动: 关闭后立即解除提示", /当前由学习联动延长屏蔽，关闭后会立即解除/],
];
/* 第 3 个元素为 true 时表示「反向断言」: 该 pattern 必须不出现(用于守 Linear 风格不被回退) */
markers.forEach(([name, re, mustAbsent]) => {
  const hit = re.test(html);
  rep(name, mustAbsent ? !hit : hit);
});

/* ---------- 2b. 后端标记 (空白页根因: /api/account 联网阻塞单线程 HTTP 服务) ---------- */
const coreFile = path.join(__dirname, "..", "src", "core.ps1");
const uiFile = path.join(__dirname, "..", "src", "webui.ps1");
const engineFile = path.join(__dirname, "..", "src", "awayfromshorts.ps1");
try {
  const core = fs.readFileSync(coreFile, "utf8");
  const ui = fs.readFileSync(uiFile, "utf8");
  const engine = fs.readFileSync(engineFile, "utf8");
  const quota = fs.readFileSync(path.join(__dirname, "..", "src", "quota-rules.ps1"), "utf8");
  const game = fs.readFileSync(path.join(__dirname, "..", "src", "game-quota.ps1"), "utf8");
  const quotaTask = fs.readFileSync(path.join(__dirname, "..", "src", "register-game-quota-task.ps1"), "utf8");
  const webTask = fs.readFileSync(path.join(__dirname, "..", "src", "register-webui-task.ps1"), "utf8");
  const backend = [
    ["后端: /api/account 本地缓存优先", /hasCache/, core],
    ["后端: 用户信息缓存落盘", /function Save-AfsAccountCache/, core],
    ["后端: 缓存缺失时限时补拉(6s)", /TimeoutSec 6/, core],
    ["后端: 登录成功写缓存", /Save-AfsAccountCache \$u/, ui],
    ["后端: 限额星期归一化", /function ConvertTo-AfsQuotaDays/, quota],
    ["后端: 限额星期生效判定", /function Test-AfsQuotaRuleActive/, quota],
    ["后端: 额度累计只处理当天星期", /\$activeRules = @\(\$Config\.rules \| Where-Object \{ Test-AfsQuotaRuleActive \$_ \$Now \}\)/, quota],
    ["后端: 额度用尽关闭按当天星期过滤", /Test-AfsQuotaRuleActive \$_ \$now/, game],
    ["后端: 限额编辑复用统一调整时段", /Get-AfsAdjustmentWindow -Now \$Now/, quota],
    ["升级: 限额任务先停旧实例", /Stop-ScheduledTask -TaskName \$taskName[\s\S]{0,180}Register-ScheduledTask/, quotaTask],
    ["升级: WebUI 先停旧实例", /Stop-ScheduledTask -TaskName \$TaskName[\s\S]{0,260}schtasks \/Create/, webTask],
    // 运行时文件(stats/activity)由主引擎高频写入, 非原子写会让面板读到半截 JSON
    ["后端: 运行时文件原子写", /function Write-AfsTextAtomic/, core],
    ["后端: 读文件短重试", /function Read-AfsTextRetry/, core],
    ["后端: stats 读取走重试+进程内缓存", /Read-AfsTextRetry -Path \$p[\s\S]{0,200}afsStatsCache/, core],
    ["后端: activity 读取走重试+进程内缓存", /Read-AfsTextRetry -Path \$p[\s\S]{0,200}afsActivityCache/, core],
    ["后端: stats 落盘用原子写", /Write-AfsTextAtomic -Path \(Get-AfsStatsPath\)/, core],
    ["后端: activity 落盘用原子写", /Write-AfsTextAtomic -Path \(Get-AfsActivityPath\)/, core],
    // 强制模式开启期间的改动处理 (防破戒):
    //   硬拒 = 屏蔽星期 / 屏蔽时段 (它们定义了"何时算非屏蔽时段")
    //   收紧 = 屏蔽网页 / 屏蔽进程 / 白名单 (可新增, 不可删除)
    // 判据集中在 core.ps1 的 Get-AfsConfigLockDiff, 离线回归见 tools/verify-lock.ps1
    ["后端: 名单签名归一化函数", /function Get-AfsListSignature/, core],
    ["后端: 名单差异摘要", /function Get-AfsListDelta/, core],
    ["后端: 名单新增项判定", /function Get-AfsListAdded/, core],
    ["后端: 名单删除项判定", /function Get-AfsListRemoved/, core],
    ["后端: 锁定分类(硬拒/放宽/收紧)", /function Get-AfsConfigLockDiff/, core],
    ["后端: 兼容入口 Test-AfsConfigLockViolation", /function Test-AfsConfigLockViolation/, core],
    ["后端: 兼容入口支持 -ForceActive", /\[switch\]\$ForceActive/, core],
    ["后端: 屏蔽星期=硬拒", /Get-AfsListSignature \$Current\.schedule\.days/, core],
    ["后端: 屏蔽时段=硬拒", /Get-AfsListSignature \$curWin\) -ne \(Get-AfsListSignature \$newWin/, core],
    ["后端: 时段删名单项=放宽", /\$rm = @\(Get-AfsListRemoved -Old \$cList -New \$nList\)/, core],
    ["后端: 时段加名单项=收紧(排队)", /\$ad = @\(Get-AfsListAdded   -Old \$cList -New \$nList\)/, core],
    ["后端: 时段名单只收紧合并", /\$add = @\(Get-AfsWindowListValue -Window \$pw -Field \$field\)/, core],
    ["后端: 关屏蔽开关=放宽", /\$curWeb\) \{/, core],
    ["后端: 加白名单=放宽", /Get-AfsListAdded   -Old \(\$Current\.whitelist\)\.sites/, core],
    ["后端: 收窄提示 widenMsg", /\$widenMsg = '强制模式开启期间, 每个时段的专属名单「只能新增, 不能删减」/, core],
    ["后端: 排队补丁生成", /function New-AfsPendingPatch/, core],
    ["后端: 补丁只收新增项", /\$windowLines\[\$wf\.Key\]\.Add\("\+ \$\(\$nw\.start\)-/, core],
    ["后端: 队列落盘 pending-config.json", /function Save-AfsPendingQueue/, core],
    ["后端: 队列读取", /function Read-AfsPendingQueue/, core],
    ["后端: 队列清除", /function Remove-AfsPendingQueue/, core],
    ["后端: 队列落地入口", /function Invoke-AfsPendingApply/, core],
    ["后端: 落地做只收紧合并", /function Merge-AfsPendingTighten/, core],
    ["后端: 合并=时段名单取并集", /\$copy\[\$field\] = @\(Get-AfsWindowListValue -Window \$tmp -Field \$field\)/, core],
    ["后端: 旧全局名单迁移到时段的入口", /function Convert-AfsLegacyBlockLists/, core],
    ["后端: 合并=白名单取交集", /if \(\$null -eq \$keepS\) \{ @\(\(\$Base\.whitelist\)\.sites\) \}/, core],
    ["后端: 合并=开关取或", /\$out\.blockWebsites = \[bool\]\(\[bool\]\$Base\.blockWebsites -or \[bool\]\$Patch\.blockWebsites\)/, core],
    ["后端: 合并只认名单字段", /# 只认名单\/开关字段与"给现有冻结时段追加名单项"/, core],
    ["后端: 生效时段内不落地", /reason = 'force-active'/, core],
    ["后端: 面板调用分类判据", /Get-AfsConfigLockDiff -Current \$curCfg -Incoming \$inCfg/, ui],
    ["后端: 强制模式开启期间拒绝放宽", /if \(\$diff\.widenMsg\) \{ throw \$diff\.widenMsg \}/, ui],
    ["后端: 生效时段内收紧改动立即合并", /Merge-AfsPendingTighten -Base \$curCfg -Patch \$np\.patch/, ui],
    ["后端: 保存响应标记已写入", /note\s+= '已保存: 收紧改动已写入配置/, ui],
    ["后端: 排队清除接口", /'\/api\/pending\/clear'/, ui],
    ["后端: config 接口带 pending", /pending\s+= \(Read-AfsPendingQueue\)/, ui],
    ["后端: status 接口带 pending", /pending\s+= \(Read-AfsPendingQueue\)/, ui],
    ["后端: 主引擎落地排队", /Invoke-AfsPendingApply -Config \$cfg/, engine],
    ["后端: 强制中禁止云端拉取覆盖", /强制模式开启中, 无法从云端拉取配置/, core],
    // 卸载守卫 (v1.5.1): 只在"强制模式此刻真正生效中"才拦 —— 开关开着但窗口外 / 非所选星期一律放行
    ["卸载守卫: 判据=此刻强制生效中", /\$fa = Test-AfsForceActive -Config \$cfg -Now \$Now/, core],
    ["卸载守卫: 窗口外放行", /if \(\$cfgOn\) \{ return \$res \}/, core],
    ["卸载守卫: 保留状态文件残留防篡改", /reason = 'force-residue'/, core],
    ["后端: force 开关/星期不可经保存更改", /\[void\]\$hardKeys\.Add\('force'\)/, core],
    ["后端: force 星期对比用签名归一", /Get-AfsListSignature \$curFwd\) -ne \(Get-AfsListSignature \$newFwd/, core],
    ["后端: 学习联动可随时关闭", /\$c\.studyHold = @\{ enabled =/, ui],
    ["后端: 学习联动关闭后立即生效", /学习联动已保存并立即生效/, ui],
  ];
  backend.forEach(([name, re, src]) => rep(name, re.test(src)));
} catch (e) { rep("读取后端脚本", false, "- " + e.message); }

/* ---------- 3. 已移除功能不得回退 ---------- */
rep("Edge 工作区屏蔽 UI 已移除", !/browserWinList|browserWinInput|browserWindows|browserSwitch/.test(html));

/* ---------- 4. 结构平衡 ---------- */
const cnt = (re) => (html.match(re) || []).length;
const navBtn = cnt(/<button type="button" class="nav-item[^>]*>/g);
rep("侧边栏按钮数 = 8", navBtn === 8, "(实际 " + navBtn + ")");
rep("无遗留 <aside>", cnt(/<aside\b/g) === 0);
rep("<nav> 标签平衡", cnt(/<nav\b/g) === cnt(/<\/nav>/g));
const panelIds = [...html.matchAll(/id="panel-([a-z]+)"/g)].map(m => m[1]);
const tabIds = [...html.matchAll(/<button type="button" class="nav-item[^"]*" data-tab="([a-z]+)"/g)].map(m => m[1]);
const sameSet = panelIds.length === tabIds.length && panelIds.every(id => tabIds.includes(id)) && tabIds.every(id => panelIds.includes(id));
rep("tab 与 panel 一一对应", sameSet, tabIds.join(","));

const css = [...html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map(m => m[1]).join("\n");
const ob = (css.match(/\{/g) || []).length, cb = (css.match(/\}/g) || []).length;
rep("CSS 大括号平衡", ob === cb, ob + "/" + cb);
rep("CSS 小括号平衡", (css.match(/\(/g) || []).length === (css.match(/\)/g) || []).length,
  (css.match(/\(/g) || []).length + "/" + (css.match(/\)/g) || []).length);
rep("文档收尾完整", /<\/body>/.test(html) && /<\/html>/.test(html));

console.log(bad ? "\nRESULT: FAIL (" + bad + " 项)" : "\nRESULT: PASS");
process.exit(bad ? 1 : 0);
