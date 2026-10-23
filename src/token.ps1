# github-token.enc 解码（三种脚本共用）
#
# 落盘格式有两种，历史上被不同代码路径写过：
#   hex    —— ConvertFrom-SecureString 的默认输出（core.ps1 Save-AfsGitHubToken 就是这种）
#   base64 —— 同一个 DPAPI blob 的 base64（apply_checkins.py 等 python 侧写入的是这种）
# 之前 push_gist/hub_config/push_phone_repo 只用 ConvertTo-SecureString 读 hex，
# 遇到 base64 文件就抛 System.FormatException「输入字符串的格式不正确」——
# 表现是 Gist 推送连续失败、手机端闸门数据一直不更新，日志里只有那一句话，很难查。
#
# 用法：. (Join-Path $here 'token.ps1'); $token = Get-AfsGithubTokenText -Path $tokPath

# PS 5.1 默认不加载 System.Security, ProtectedData 会报「找不到类型」
try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }

# 解出来的明文不能直接拿去拼 HTTP 头：
#   · 本机这份 blob 解开是 "\x02(ghp_xxx"（前面带了 2 个字节的私有前缀），
#     带控制字符会报「指定的值含有无效的控制字符」(python 侧同样只做了 rstrip)。
# 所以统一走一遍清洗：先剔控制字符，再按 GitHub token 的形状取出来。
function Format-AfsGithubToken {
    param([string]$Text)
    if (-not $Text) { return $null }
    $clean = ($Text -replace '[^\x20-\x7E]', '').Trim()
    $m = [regex]::Match($clean, '(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})')
    if ($m.Success) { return $m.Value }
    return $clean.Trim('(', ')', ' ')
}

function Get-AfsGithubTokenText {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $raw = ([System.IO.File]::ReadAllText($Path)).Trim()
    if (-not $raw) { return $null }

    # hex：长度偶数、全 0-9a-f
    if ($raw -match '^[0-9a-fA-F]+$' -and ($raw.Length % 2 -eq 0)) {
        $sec = ConvertTo-SecureString $raw
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return ([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)).Trim() }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }

    # base64：DPAPI blob 直接解开，SecureString 内部是 UTF-16LE
    $bytes = [Convert]::FromBase64String($raw)
    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return Format-AfsGithubToken ([System.Text.Encoding]::Unicode.GetString($plain))
}
