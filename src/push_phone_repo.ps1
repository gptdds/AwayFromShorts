# Push local AwayFromShorts-Phone working copy to GitHub via Git Data API.
# - Token comes from the PC app's DPAPI store (has repo scope).
# - Batch commit: blobs -> tree -> commit -> update ref. Binary (apk) supported.
$ErrorActionPreference = 'Stop'

$here  = 'C:\Users\nj\AppData\Local\AwayFromShorts\src'
$root  = 'C:\Users\nj\WorkBuddy\AwayFromShorts-Phone'
$owner = 'gptdds'
$repo  = 'AwayFromShorts-Phone'
$branch = 'main'

$files = @(
    @{ p = 'dpc/java/com/afs/guard/Rule.java';             l = 'dpc\java\com\afs\guard\Rule.java' },
    @{ p = 'dpc/java/com/afs/guard/RuleStore.java';        l = 'dpc\java\com\afs\guard\RuleStore.java' },
    @{ p = 'dpc/java/com/afs/guard/Guard.java';            l = 'dpc\java\com\afs\guard\Guard.java' },
    @{ p = 'dpc/java/com/afs/guard/GuardService.java';     l = 'dpc\java\com\afs\guard\GuardService.java' },
    @{ p = 'dpc/java/com/afs/guard/StudyGate.java';        l = 'dpc\java\com\afs\guard\StudyGate.java' },
    @{ p = 'dpc/java/com/afs/guard/AppListActivity.java';  l = 'dpc\java\com\afs\guard\AppListActivity.java' },
    @{ p = 'dpc/build.sh';                                 l = 'dpc\build.sh' },
    @{ p = 'dpc/STUDYGATE.md';                              l = 'dpc\STUDYGATE.md' },
    @{ p = 'checkin/AndroidManifest.xml';                  l = 'checkin\AndroidManifest.xml' },
    @{ p = 'checkin/README.md';                            l = 'checkin\README.md' },
    @{ p = 'checkin/build.sh';                             l = 'checkin\build.sh' },
    @{ p = 'checkin/java/com/afs/checkin/MainActivity.java'; l = 'checkin\java\com\afs\checkin\MainActivity.java' },
    @{ p = 'checkin/java/com/afs/checkin/Store.java';      l = 'checkin\java\com\afs\checkin\Store.java' },
    @{ p = 'checkin/java/com/afs/checkin/Gist.java';       l = 'checkin\java\com\afs\checkin\Gist.java' },
    @{ p = 'checkin/res/drawable/ic_launcher.xml';         l = 'checkin\res\drawable\ic_launcher.xml' },
    @{ p = 'checkin/res/values/strings.xml';               l = 'checkin\res\values\strings.xml' },
    @{ p = 'dpc/test/java/com/afs/guard/GuardTest.java';   l = 'dpc\test\java\com\afs\guard\GuardTest.java' },
    @{ p = 'afs-guard.apk';                                l = 'afs-guard.apk' }
)

$missing = @()
foreach ($f in $files) {
    $full = Join-Path $root $f.l
    if (-not (Test-Path $full)) { $missing += $f.l }
}
if ($missing.Count -gt 0) { "MISSING: " + ($missing -join ', '); exit 1 }
"all files present"

. (Join-Path $here 'token.ps1')
$token = Get-AfsGithubTokenText -Path (Join-Path $here 'github-token.enc')
if (-not $token) { "token decrypt failed"; exit 1 }

try {
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
} catch { }

$headers = @{
    'Authorization' = 'token ' + $token
    'User-Agent'    = 'AFS-Phone-Push'
    'Accept'        = 'application/vnd.github+json'
}

function GH {
    param([string]$Method, [string]$Path, $Body)
    $uri = 'https://api.github.com' + $Path
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 10 -Compress
        # ★ 必须显式转 UTF-8 字节：直接传 string 时 PS5.1 按 Latin-1 发送，
        #   中文会全变成 "????"（commit message 就这么丢过一次）
        $utf8 = [System.Text.Encoding]::UTF8.GetBytes($json)
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body $utf8 `
            -ContentType 'application/json; charset=utf-8' -TimeoutSec 45
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -TimeoutSec 45
}

"---- read base ref ----"
$ref = GH -Method Get -Path "/repos/$owner/$repo/git/ref/heads/$branch"
$baseSha = $ref.object.sha
$baseCommit = GH -Method Get -Path "/repos/$owner/$repo/git/commits/$baseSha"
$baseTree = $baseCommit.tree.sha
"base commit: $baseSha"
"base tree:   $baseTree"

"---- upload blobs ----"
$tree = @()
foreach ($f in $files) {
    $full = Join-Path $root $f.l
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $b64 = [Convert]::ToBase64String($bytes)
    $blob = GH -Method Post -Path "/repos/$owner/$repo/git/blobs" -Body @{ content = $b64; encoding = 'base64' }
    $tree += @{ path = $f.p; mode = '100644'; type = 'blob'; sha = $blob.sha }
    "  ok {0} ({1} bytes)" -f $f.p, $bytes.Length
}

"---- build tree ----"
$newTree = GH -Method Post -Path "/repos/$owner/$repo/git/trees" -Body @{ base_tree = $baseTree; tree = $tree }
"tree: $($newTree.sha)"

"---- commit ----"
$msg = @(
    'feat: v1.10.6 手机上滑打卡（checkin/），先解闸后补台账',
    '',
    '需求：手机上打卡要翻网页、找目标卡、点按钮，太绕。',
    '',
    '一、新 App checkin/ —— 上滑即打卡',
    '* 独立 APK，28KB，打开就是一列目标；选中的那张往上滑就提交，',
    '  没滑够松手会回弹（不会误打），打完自动切下一个',
    '* 长按卡片改这一笔的数量；建议量复用学习台的 suggestOf 算法',
    '* 离线可用：先写本地队列再异步推 Gist，失败只标「待记账 N 条」',
    '',
    '二、为什么必须绕 Gist',
    '学习台页面只能活在 WorkBuddy 宿主的 iframe 里 —— inject.js 检测到',
    '顶层窗口就 document.write 一段空白并 window.stop()，数据层',
    '__SMART_PAGE__.database 的身份也在宿主那边。独立 App 拿不到写入凭据，',
    '所以手机只能写 Gist，由 PC 代记账：',
    '  打卡 -> checkin-queue.json -> apply_checkins.py -> 学习台打卡表',
    '',
    '三、守卫这边先解闸',
    '* StudyGate 增加读 checkin-queue.json',
    '* 队列带 pendingAfter（合并手机打卡后还剩几个目标）',
    '  -1 = 没打卡，0 = 补齐了 -> 立刻不再延长冻结，>0 = 照常冻',
    '  ★ 必须是 ==0，写成"队列非空就放行"等于打一个目标就把剩下的全豁免',
    '* 拉取失败保持上次的值，不会网络抖一下就把"已打卡"抹回去',
    '* 新状态 ST_QUEUED，卡片显示「手机上已打卡，等电脑记账」',
    '',
    '四、PC 端',
    '* check_study.py 输出 goals 明细（id/名称/单位/建议量/今日是否已打）',
    '  手机要"选一个目标打"，光有 pending 数字没法选',
    '* 新增 apply_checkins.py：读队列 -> 写打卡表 -> 清队列',
    '  用 localId 作「记录ID」做幂等，重跑/半路失败都不会重复记账',
    '* study_sync.py 串成四步，apply_checkins 排最前（否则 check_study',
    '  看不到手机刚打的卡）',
    '',
    '另修：push_gist.ps1 的 Invoke-RestMethod 按 Latin-1 发 string body，',
    '目标名/单位全变成 "?"（和当初 commit message 乱码同一个坑），',
    '改发 UTF-8 byte[]',
    '',
    '测试 169 项全过（新增 18 项队列判定断言）',
    '',
    '注：checkin.apk 不随仓库发布 —— 构建时会内置个人 GitHub token，',
    '只在本机 build.sh 生成。源码里没有凭据。',
    ''
) -join "`n"
$commit = GH -Method Post -Path "/repos/$owner/$repo/git/commits" -Body @{
    message = $msg; tree = $newTree.sha; parents = @($baseSha)
}
"commit: $($commit.sha)"
"$($commit.html_url)"

"---- update ref ----"
$null = GH -Method Patch -Path "/repos/$owner/$repo/git/refs/heads/$branch" -Body @{ sha = $commit.sha; force = $false }
"PUSH_OK $($commit.sha)"
