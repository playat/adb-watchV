#Requires -Version 5.1
<#
.SYNOPSIS
    交互式连接设备，然后监听 Shift+↑ / Shift+↓ / Shift+空格，
    向 adb 设备发送「上滑 / 下滑 / 屏幕正中点按」手势。

.DESCRIPTION
    启动后的交互流程：

      [1] 先扫一次 mDNS（只扫一次，不等待）：扫到当前端口就直接连上；
          再跑 adb devices -l 看有没有已经连接的设备
          · 有 -> 用上下方向键选（回车确认），最后一项是"连接新设备…"
          · 没有 -> 直接进引导

      [2] 引导（连接新设备），三连尝试，一次比一次多要信息：
          第 1 次：mDNS 再扫一次 -> 列出 -> 选 -> connect
          第 2 次：手动输 IP:端口 -> connect
          第 3 次：配对 IP:端口 + 配对码 -> adb pair -> 再 connect
          IP 输入框预填了 "192.168"（内网基本都是这个开头），接着往下敲就行。

      [3] 连上之后才开始监听键盘：
          Shift + ↑     上滑（手指从屏幕下方划到上方 -> 内容往上滚）
          Shift + ↓     下滑（手指从屏幕上方划到下方 -> 内容往下滚）
          Shift + 空格  点按屏幕正中（相当于在屏幕中央轻点一下）
          按住不放会连续滑动（一次滑动做完就补发下一次）。

          每次动作【不新增任何输出行】：只把输出最后那一行的计数改写一遍
          （上滑 / 下滑 / 点按 次数原地刷新），所以按多少次屏幕都不会被刷满。
          Ctrl+C 或关窗口停止时，再给一行合计。

    不落盘任何东西：设备地址、配对码都不记。每次启动重新扫一次 mDNS，
    手机重开了无线调试也能自己找到新端口。

    默认是【全局热键】：脚本窗口不在前台也照样触发，方便你盯着手机屏幕操作。
    代价是脚本运行期间，Shift+↑ / Shift+↓ / Shift+空格 在整个系统都被本脚本吃掉
    （包括文本编辑器里的「选中到行首/行尾」，以及中文输入法的全角/半角切换）。
    不想影响其它软件就加 -ConsoleOnly：只在这个控制台窗口有焦点时生效。

    停止监听：关掉窗口，或者按 Ctrl+C。
    进程一结束，热键由系统自动释放，不会留下幽灵监听。

    adb 用的是脚本目录里自带的那个（按 .\adb\adb.exe -> .\adb.exe
    -> .\platform-tools\adb.exe 的顺序找），不依赖宿主机 PATH，
    所以整个文件夹拷到别的电脑上就能直接跑。
    都找不到才会退回宿主机 PATH 里的 adb，并给一句黄色提醒。

.EXAMPLE
    .\start-watchV.cmd                       # 双击这个，最省事
.EXAMPLE
    .\start-watchV.cmd -Setup                # 跳过设备菜单，直接进连接新设备流程
.EXAMPLE
    .\start-watchV.cmd -Device 192.168.1.100:5555 -Duration 250
.EXAMPLE
    .\start-watchV.cmd -ConsoleOnly          # 只监听本窗口，不抢系统热键
#>
[CmdletBinding()]
param(
    # 目标设备序列号（adb devices 里那一列）。指定了就直接用，不弹菜单、不引导
    [string]$Device = "",

    # 跳过"已连接设备"菜单，直接走一遍配对/连接流程
    [switch]$Setup,

    # 单次滑动持续时间(ms)。太大像拖拽，太小容易被识别成 fling，250~400 比较稳
    [ValidateRange(50, 2000)]
    [int]$Duration = 300,

    # 滑动终点/起点在屏幕高度上的比例：近端(屏幕下方) / 远端(屏幕上方)
    [ValidateRange(0.05, 0.95)]
    [double]$NearRatio = 0.8,

    [ValidateRange(0.05, 0.95)]
    [double]$FarRatio = 0.2,

    # 只监听本控制台窗口，不抢系统的 Shift+↑ / Shift+↓ / Shift+空格
    [switch]$ConsoleOnly
)

# 只用来兜住"我自己写错的代码"；adb 的 stderr 走单独封装，不受影响
$ErrorActionPreference = "Stop"


# ---------------------------------------------------------------- 小工具
function Write-Stamp {
    param(
        [string]$Message,
        [string]$Color = 'Gray'
    )
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor $Color
}

<# 这个脚本要靠键盘交互（方向键菜单 + Read-Host）。
   如果 stdin/stdout 被重定向（比如 piped、被别的程序接管），
   [Console]::ReadKey 会直接抛异常，菜单也画不出来 —— 提前判断好降级。 #>
function Test-Interactive {
    try {
        if ([Console]::IsInputRedirected)  { return $false }
        if ([Console]::IsOutputRedirected) { return $false }
        return $true
    } catch {
        return $false
    }
}


# ---------------------------------------------------------------- adb 封装
# 用哪个 adb：优先脚本目录里自带的那个，不依赖宿主机 PATH
$script:AdbExe = ''

<# 定位 adb 可执行文件。顺序是"自带优先，PATH 兜底"：
       <脚本目录>\adb\adb.exe          <- 推荐放法（连同两个 AdbWin*.dll）
       <脚本目录>\adb.exe
       <脚本目录>\platform-tools\adb.exe
       宿主机 PATH 里的 adb            <- 兜底，会附带一句黄色提醒
   整个文件夹拷到别的电脑也能直接跑，这是这么写的目的。 #>
function Resolve-AdbPath {
    $root = $PSScriptRoot
    if (-not $root) { $root = (Get-Location).Path }

    $relative = @(
        'adb\adb.exe',
        'adb.exe',
        'platform-tools\adb.exe'
    )
    foreach ($rel in $relative) {
        $candidate = Join-Path $root $rel
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $fromPath = Get-Command adb -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }

    return ''
}

# 最近一次 adb 调用的 stderr 原文（adb 的报错基本都往 stderr 写）
$script:adbStderr = @()

# 最近一次 adb 调用是不是超时被掐掉的（124 这个退出码太抽象，单独记一下）
$script:adbTimedOut = $false

<# PS 5.1 的 ProcessStartInfo 没有 ArgumentList（那是 .NET Core 才加的），
   只能自己拼命令行。参数里带空格的用双引号包一下就行 —— 我们传的参数都很干净。 #>
function ConvertTo-ArgToken {
    param([string]$Token)
    if (-not $Token) { return '""' }
    if ($Token -match '\s') { return '"' + $Token + '"' }
    return $Token
}

<# 统一的 adb 调用出口。

   为什么不用 `& adb.exe ...` 直接跑：那样【没法设超时】。
   手机拿走、换了 IP、端口没开的时候，adb connect / adb pair 会闷在那儿
   等 Windows 的 TCP 重试（几十秒到两分钟），表现就是"一直卡在连接 / 卡在配对"。
   这里用 Process 跑，到点就 Kill，最多等 TimeoutSec 秒，不会再无限期挂着。

   返回 stdout 行（数组）；stderr 去读 $script:adbStderr；
   退出码写到 $global:LASTEXITCODE（函数里跑原生命令，默认传不到调用方）；
   超时被掐掉的，$script:adbTimedOut = $true，退出码记 124。 #>
function Invoke-Adb {
    param(
        [string[]]$Arguments,
        [int]$TimeoutSec = 30
    )

    $script:adbStderr   = @()
    $script:adbTimedOut = $false

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $script:AdbExe
    $psi.Arguments              = ((@($Arguments) | ForEach-Object { ConvertTo-ArgToken $_ }) -join ' ')
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $workDir = $PSScriptRoot
    if (-not $workDir) { $workDir = (Get-Location).Path }
    $psi.WorkingDirectory = $workDir

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    try {
        $null = $proc.Start()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            $script:adbTimedOut = $true
            try { $proc.Kill() } catch { }
            try { $null = $proc.WaitForExit(2000) } catch { }
            $script:adbStderr += "（等了 ${TimeoutSec} 秒没回应，已强制结束）"
        }

        $outText = ''
        $errText = ''
        try { $outText = $outTask.Result } catch { }
        try { $errText = $errTask.Result } catch { }

        if ($errText) {
            $script:adbStderr += @($errText -split "`r?`n" | Where-Object { $_ -ne '' })
        }

        if ($script:adbTimedOut) {
            $global:LASTEXITCODE = 124
        } else {
            $code = 1
            try { $code = $proc.ExitCode } catch { }
            $global:LASTEXITCODE = $code
        }

        if (-not $outText) { return @() }
        return @($outText -split "`r?`n" | Where-Object { $_ -ne '' })
    } finally {
        try { $proc.Dispose() } catch { }
    }
}


<# 把最近一次 adb 调用的 stdout + stderr 拼成一段文本，
   用来做"成功了没"的文本判定（adb connect / pair 的退出码并不可靠）。 #>
function Get-AdbCombinedText {
    param([object[]]$StdOut)

    $parts = @()
    if ($StdOut) { $parts += @($StdOut) }
    if ($script:adbStderr) { $parts += @($script:adbStderr) }
    return ($parts -join "`n")
}

<# 打印一条 adb 命令的原始结果：命令行 + 退出码 + stdout/stderr 原文。
   退出码由调用方传进来（不靠函数里读 $LASTEXITCODE，省得又踩作用域的坑）。 #>
function Write-AdbRaw {
    param(
        [string[]]$Arguments,
        [object[]]$StdOut,
        [int]$ExitCode
    )

    if ($StdOut) { $outBrief = ($StdOut -join ' / ') } else { $outBrief = '(空)' }
    if ($script:adbStderr) { $errBrief = ($script:adbStderr -join ' / ') } else { $errBrief = '(空)' }

    if ($ExitCode -ne 0) { $codeColor = 'Yellow' } else { $codeColor = 'DarkGray' }
    if ($script:adbStderr) { $errColor = 'Yellow' } else { $errColor = 'DarkGray' }

    Write-Host "    cmd  : adb $($Arguments -join ' ')" -ForegroundColor DarkGray
    Write-Host "    exit : $ExitCode" -ForegroundColor $codeColor
    Write-Host "    out  : $outBrief" -ForegroundColor DarkGray
    Write-Host "    err  : $errBrief" -ForegroundColor $errColor

    # 有原文就逐行摊开，方便直接复制去喂搜索引擎
    if ($StdOut) { foreach ($line in $StdOut) { Write-Host "      > $line" -ForegroundColor DarkGray } }
    if ($script:adbStderr) { foreach ($line in $script:adbStderr) { Write-Host "      ! $line" -ForegroundColor Yellow } }
}


# ---------------------------------------------------------------- 设备列举
<# 拿 adb 的完整设备列表（含离线/未授权），不只看在线的那几台。
   adb devices -l 会在状态后面带 model:xxx 之类的附加字段，顺手解析出型号。 #>
function Get-DeviceList {

    $raw = Invoke-Adb @('devices', '-l')
    $result = New-Object System.Collections.Generic.List[object]

    # 只认这些状态。不这么筛的话，"adb server is out of date." 这类噪声行
    # 也会被下面那条正则匹配成 serial=adb / state=server，混进菜单里。
    $knownStates = @('device', 'offline', 'unauthorized', 'bootloader',
                     'recovery', 'sideload', 'rescue', 'host', 'no')

    foreach ($line in @($raw)) {
        if (-not $line) { continue }
        if ($line -match '^\s*List of devices') { continue }
        if ($line -match '^\s*\*') { continue }      # * daemon not running 之类
        if ($line -notmatch '^(\S+)\s+(\S+)(.*)$') { continue }

        $serial = $Matches[1]
        $state  = $Matches[2]
        $rest   = $Matches[3]

        if ($knownStates -notcontains $state) { continue }

        $model = ''
        if ($rest -match 'model:(\S+)') { $model = $Matches[1] }

        $result.Add([pscustomobject]@{
            Serial = $serial
            State  = $state
            Model  = $model
        })
    }
    return (Remove-DeviceAlias -Devices $result)
}

<# 去重：Android 11+ 的无线调试，同一台手机经常同时登记成两个身份 ——
       · 192.168.x.x:端口                       （手动 adb connect 注册的）
       · adb-xxxxxxxx-xxxxxx._adb-tls-connect._tcp  （mDNS 自动连接注册的）
   两个都 "device"、model 一样，菜单里就会出现两条指向同一台机器。
   这里把 mDNS 别名那条丢掉 —— IP 形式更明确，出问题也好排查。

   代价：两台【同型号】手机、一台走 IP 一台走 mDNS 时，会误丢一台。
   这种场景很少见，真遇到了用 -Device 显式指定。 #>
function Remove-DeviceAlias {
    param([object[]]$Devices)

    $list = @($Devices)
    if ($list.Count -eq 0) { return $list }

    $aliasPattern = '\._adb-tls-connect\._tcp$'

    $plain = @($list | Where-Object { $_.Serial -notmatch $aliasPattern })
    $alias = @($list | Where-Object { $_.Serial -match     $aliasPattern })

    if ($alias.Count -eq 0) { return $list }   # 没有别名，原样返回

    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($d in $plain) { $kept.Add($d) }

    foreach ($a in $alias) {
        $isDuplicate = $false
        foreach ($p in $plain) {
            if ($p.Model -and $a.Model -and $p.Model -eq $a.Model) { $isDuplicate = $true; break }
        }
        if (-not $isDuplicate) { $kept.Add($a) }
    }

    return $kept
}

function Test-DeviceOnline {
    param([string]$Address)
    if (-not $Address) { return $false }
    $online = @(Get-DeviceList | Where-Object { $_.State -eq 'device' })
    foreach ($d in $online) { if ($d.Serial -eq $Address) { return $true } }
    return $false
}

<# adb 的状态字眼翻译成人话，省得菜单里出现光秃秃一个 "no" #>
function Get-StateText {
    param([string]$State)
    switch ($State) {
        'device'       { 'device' }
        'unauthorized' { '未授权' }
        'offline'      { '离线' }
        'no'           { '无权限' }
        'bootloader'   { 'fastboot' }
        'recovery'     { 'recovery' }
        'sideload'     { 'sideload' }
        default        { $State }
    }
}


# ---------------------------------------------------------------- 交互输入
<# 方向键菜单。返回被选中项的索引；按 Esc 返回 -1。

   实现方式：先把整个列表"占位"打印出来，记住列表首行的位置，
   之后每次按键就用 SetCursorPosition 回到那一行重画 —— 所以标题不会被刷掉，
   菜单也不会滚屏。这是控制台里做选择菜单最稳的做法。 #>
function Read-MenuChoice {
    param(
        [Parameter(Mandatory)][string[]]$Items,
        [string]$Title = ''
    )

    $count = @($Items).Count
    if ($count -eq 0) { return -1 }

    $index = 0

    $width = 80
    try { $width = [Console]::WindowWidth } catch { }
    if (-not $width -or $width -lt 24) { $width = 80 }
    $padWidth = $width - 1

    if ($Title) { Write-Host $Title -ForegroundColor Cyan }
    Write-Host "  ↑/↓ 移动，回车确认，Esc 取消" -ForegroundColor DarkGray

    $listTop = 0
    try { $listTop = [Console]::CursorTop } catch { }

    # 先用空行把位置占掉，避免重画时把后面的内容（比如光标）挤走
    $blank = ' ' * $padWidth
    for ($i = 0; $i -lt $count; $i++) { Write-Host $blank }

    $oldVisible = $true
    try { $oldVisible = [Console]::CursorVisible } catch { }
    try { [Console]::CursorVisible = $false } catch { }

    $result = -1
    try {
        $running = $true
        while ($running) {

            for ($i = 0; $i -lt $count; $i++) {
                try { [Console]::SetCursorPosition(0, $listTop + $i) } catch { }

                $text = '  ' + $Items[$i]
                if ($text.Length -ge $padWidth) { $text = $text.Substring(0, $padWidth - 1) }
                $text = $text.PadRight($padWidth)

                if ($i -eq $index) {
                    Write-Host $text -ForegroundColor Black -BackgroundColor Cyan
                } else {
                    Write-Host $text -ForegroundColor Gray
                }
            }

            try { [Console]::SetCursorPosition(0, $listTop + $count) } catch { }

            $key = [Console]::ReadKey($true)
            $k = $key.Key

            if ($k -eq [ConsoleKey]::UpArrow) {
                if ($index -eq 0) { $index = $count - 1 } else { $index = $index - 1 }
            } elseif ($k -eq [ConsoleKey]::DownArrow) {
                if ($index -eq $count - 1) { $index = 0 } else { $index = $index + 1 }
            } elseif ($k -eq [ConsoleKey]::Enter) {
                $result = $index
                $running = $false
            } elseif ($k -eq [ConsoleKey]::Escape) {
                $result = -1
                $running = $false
            }
        }
    } finally {
        try { [Console]::CursorVisible = $oldVisible } catch { }
        try { [Console]::ResetColor() } catch { }
        try { [Console]::SetCursorPosition(0, $listTop + $count) } catch { }
    }

    return $result
}

<# 一行输入的编辑逻辑（纯函数：只算 buffer 和光标下标，不碰控制台）。

   单独拆出来是为了能测 —— "退格之后内容对不上"正是这里最容易错的地方，
   拆成纯函数就能拿假按键一遍遍验，不用真人在终端里敲。 #>
function Edit-InputBuffer {
    param(
        [string]$Buffer = '',
        [int]$Caret = 0,
        [Parameter(Mandatory)][System.ConsoleKeyInfo]$Key
    )

    if ($Caret -lt 0) { $Caret = 0 }
    if ($Caret -gt $Buffer.Length) { $Caret = $Buffer.Length }

    $k = $Key.Key

    if ($k -eq [ConsoleKey]::Enter) {
        return [pscustomobject]@{ Buffer = $Buffer; Caret = $Caret; Action = 'submit' }
    }

    if ($k -eq [ConsoleKey]::Escape) {
        return [pscustomobject]@{ Buffer = ''; Caret = 0; Action = 'clear' }
    }

    if ($k -eq [ConsoleKey]::Backspace) {
        if ($Caret -gt 0) {
            $Buffer = $Buffer.Remove($Caret - 1, 1)
            $Caret  = $Caret - 1
        }
        return [pscustomobject]@{ Buffer = $Buffer; Caret = $Caret; Action = 'none' }
    }

    if ($k -eq [ConsoleKey]::Delete) {
        if ($Caret -lt $Buffer.Length) { $Buffer = $Buffer.Remove($Caret, 1) }
        return [pscustomobject]@{ Buffer = $Buffer; Caret = $Caret; Action = 'none' }
    }

    if ($k -eq [ConsoleKey]::LeftArrow) {
        if ($Caret -gt 0) { $Caret = $Caret - 1 }
        return [pscustomobject]@{ Buffer = $Buffer; Caret = $Caret; Action = 'none' }
    }

    if ($k -eq [ConsoleKey]::RightArrow) {
        if ($Caret -lt $Buffer.Length) { $Caret = $Caret + 1 }
        return [pscustomobject]@{ Buffer = $Buffer; Caret = $Caret; Action = 'none' }
    }

    if ($k -eq [ConsoleKey]::Home) {
        return [pscustomobject]@{ Buffer = $Buffer; Caret = 0; Action = 'none' }
    }

    if ($k -eq [ConsoleKey]::End) {
        return [pscustomobject]@{ Buffer = $Buffer; Caret = $Buffer.Length; Action = 'none' }
    }

    # 只收 ASCII 可见字符。
    # 全角数字、全角空格、中文标点长得像，但根本不是同一个字符：
    # 全角数字连正则的 \d 都能骗过去，最后就是"看着一模一样、就是连不上"。
    $ch = $Key.KeyChar
    if ($ch -and ([int]$ch -ge 32) -and ([int]$ch -le 126)) {
        $Buffer = $Buffer.Insert($Caret, [string]$ch)
        $Caret  = $Caret + 1
    }

    return [pscustomobject]@{ Buffer = $Buffer; Caret = $Caret; Action = 'none' }
}

<# 自定义行输入，支持【预填文本】和退格 / 方向键编辑。
   Read-Host 做不到预填，所以自己接键。

   重画方式：记住输入区起点（提示语之后的位置），每次改动都
   「回到起点 -> 整行重写 -> 用空格盖掉上次多出来的部分 -> 光标挪回正确位置」。

   以前是靠 [Console]::Write("\b \b") 发退格符，这招不可靠：有些终端/编码下
   光标不左移，只留下一个空格，屏幕上就多出一串空格，和真实内容对不上。
   而人是照着屏幕改地址的 —— 屏幕骗人，改出来的就是 192.168.88.99 这种
   看着对、其实多一位的地址，然后卡在连接。现在整行重绘，屏幕和 buffer 永远一致。 #>
function Read-Line {
    param(
        [string]$Prompt = '',
        [string]$Prefill = ''
    )

    Write-Host $Prompt -ForegroundColor Cyan -NoNewline

    # 输入区起点 = 提示语结束的位置
    $anchorLeft = 0
    $anchorTop  = 0
    try {
        $anchorLeft = [Console]::CursorLeft
        $anchorTop  = [Console]::CursorTop
    } catch { }

    $buffer   = $Prefill
    $caret    = $buffer.Length
    $drawnLen = 0        # 上一帧画了几个字符，用来算要盖掉多少空格
    $needDraw = $true
    $submit   = $false

    while ($true) {

        if ($needDraw) {
            try {
                [Console]::SetCursorPosition($anchorLeft, $anchorTop)
                [Console]::Write($buffer)
                if ($drawnLen -gt $buffer.Length) {
                    [Console]::Write((' ' * ($drawnLen - $buffer.Length)))
                }
                [Console]::SetCursorPosition($anchorLeft + $caret, $anchorTop)
            } catch {
                # 光标定位不可用（输出被重定向等）时，至少别把内容吞掉
                [Console]::Write($buffer)
            }
            $drawnLen = $buffer.Length
            $needDraw = $false
        }

        if ($submit) {
            Write-Host ''
            return $buffer.Trim()
        }

        $key  = [Console]::ReadKey($true)
        $edit = Edit-InputBuffer -Buffer $buffer -Caret $caret -Key $key

        $buffer   = $edit.Buffer
        $caret    = $edit.Caret
        $needDraw = $true

        if ($edit.Action -eq 'submit') { $submit = $true }
    }
}

<# 地址格式校验：只接受 "IP" 或 "IP:端口"。

   两个作用：
     · 防"预填了 192.168、用户又从头发了一遍"，那样会拼成 192.168192.168.88.22；
     · 防"看着像其实是别的字符" —— 空白（含全角空格）、全角数字、中文冒号一律不认。
   用 [0-9] 而不是 \d：在 .NET 里 \d 会匹配全角数字，那是坑。 #>
function Test-HostPort {
    param([string]$Text)

    if (-not $Text) { return $false }
    if ($Text -match '\s') { return $false }        # 任何空白都不允许
    return ($Text -match '^[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]{1,5})?$')
}

<# 把 "IP:端口" 或单纯的 "IP" 解析出来，没端口就用默认端口补上 #>
function Parse-HostPort {
    param(
        [string]$Text,
        [string]$DefaultPort = '5555'
    )

    $t = ''
    if ($Text) { $t = $Text.Trim() }
    if (-not $t) { return $null }

    if ($t -match '^(.+):(\d+)$') {
        return [pscustomobject]@{ Host = $Matches[1].Trim(); Port = $Matches[2] }
    }
    return [pscustomobject]@{ Host = $t; Port = $DefaultPort }
}


<# 快速探一下 IP:端口 通不通，最多等 TimeoutMs 毫秒。

   有了它，端口没开就能当场说出来，而不是让 adb 去闷等几十秒 ——
   "无线调试被关掉""端口变了""手机被 DHCP 换了 IP"这三种情况，都会在这一步露馅。 #>
function Test-HostPortOpen {
    param(
        [string]$Address,
        [int]$Port,
        [int]$TimeoutMs = 1500
    )

    if (-not $Address -or -not $Port) { return $false }

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($Address, $Port)
        if (-not $task.Wait($TimeoutMs)) { return $false }
        return $client.Connected
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

<# 把 adb 服务重启一遍。

   手机拿远再回来之后，adb 服务里通常还留着两样脏东西：
     · 一条指向上次那个端口 / IP 的死连接（adb connect 会回 "already connected"，其实早死了）
     · 旧的 mDNS 缓存（端口明明变了，它还在报老端口）
   kill-server 是唯一能一次清掉这两样的动作。清完再扫，看到的才是手机现在真正的端口。

   只杀电脑这边的 adb 服务：不动 USB 设备，也不影响手机上的调试授权。 #>
function Restart-AdbServer {
    Write-Stamp "重启 adb 服务（清掉上次的死连接和旧 mDNS 缓存）..." DarkGray
    Invoke-Adb @('kill-server') -TimeoutSec 10 | Out-Null
    Start-Sleep -Milliseconds 300
    $null = Invoke-Adb @('start-server') -TimeoutSec 20

    if ($script:adbTimedOut -or $LASTEXITCODE -ne 0) {
        Write-Stamp "adb 服务没起来，后面大概率连不上。" Yellow
        foreach ($line in $script:adbStderr) { Write-Host "      ! $line" -ForegroundColor Yellow }
        return $false
    }
    return $true
}

<# 只取 connect 服务的地址。

   配对端口（_adb-tls-pairing）【不能用来连接】，混进候选里只会白试一场；
   反过来，拿连接端口去配对更糟：端口是开的，adb 会一直等那个永远不来的配对握手。 #>
function Get-MdnsConnectTargets {
    param([string]$HostName = '')

    $list = @(Get-MdnsServices | Where-Object { $_.Service -eq 'connect' })
    if ($HostName) { $list = @($list | Where-Object { $_.Host -eq $HostName }) }

    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($d in $list) {
        $addr = "$($d.Host):$($d.Port)"
        if (-not $targets.Contains($addr)) { $targets.Add($addr) }
    }
    return $targets.ToArray()
}


# ---------------------------------------------------------------- 配对 + 连接
<# mDNS 扫描：只扫一次，不等、不循环。

   以前这里会反复重扫最多 8 秒，等手机把广播发出来。实际用下来体验很差：
   手机没开无线调试时，每次启动都白等 8 秒，然后照样失败。
   现在就是「问一句，有就有，没有就算」—— 扫不到直接走后面的手动输入 / 配对流程。 #>
function Get-MdnsServices {

    $found = New-Object System.Collections.Generic.List[object]
    $raw = Invoke-Adb @('mdns', 'services')

    foreach ($line in @($raw)) {
        if (-not $line) { continue }
        if ($line -match '^\s*List of') { continue }
        # 只关心 connect / pairing 两种服务
        if ($line -match '_adb-tls-(connect|pairing)\._tcp\.?\s+([0-9\.]+):(\d+)') {
            $found.Add([pscustomobject]@{
                Service = $Matches[1]     # connect / pairing
                Host    = $Matches[2]
                Port    = $Matches[3]
            })
        }
    }

    return $found
}

<# 尝试连接一个地址，返回是否真的连上了。

   顺序：先探端口（不通直接判失败，不让 adb 去卡）
        -> adb disconnect（只断 TCP，不碰 USB）
        -> adb connect（带超时）
        -> 看看设备列表里到底有没有它

   重试几次是必要的：手机刚重开无线调试的头一两秒端口还没 listen，
   第一次 connect 常常直接 "Connection refused"，隔一秒再连就上了 ——
   这也是"反复试好几次突然又能连"的由来之一。 #>
function Try-Connect {
    param(
        [string]$Target,
        [int]$Attempts = 3,
        [switch]$Compact          # 启动时自动连用：只报结果，不摊 adb 原文
    )

    if (-not $Target) { return $false }

    $hp = Parse-HostPort -Text $Target
    if (-not $hp) { return $false }
    $portNumber = 0
    [void][int]::TryParse($hp.Port, [ref]$portNumber)

    if (-not (Test-HostPortOpen -Address $hp.Host -Port $portNumber)) {
        Write-Stamp "$Target 端口没开（没监听 / 端口已经变了）" Yellow
        return $false
    }

    Invoke-Adb @('disconnect') -TimeoutSec 10 | Out-Null

    for ($i = 1; $i -le $Attempts; $i++) {

        if ($i -gt 1) {
            Write-Stamp "第 $i 次重试连接 $Target ..." DarkGray
            Start-Sleep -Milliseconds 1200
        } elseif ($Compact) {
            Write-Stamp "连接 $Target ..." DarkGray
        } else {
            Write-Stamp "连接：adb connect $Target" Yellow
        }

        $out  = Invoke-Adb @('connect', $Target) -TimeoutSec 20
        $text = Get-AdbCombinedText -StdOut $out

        # 第一次给全量原文（方便排查），重试只给一行结论，免得刷屏
        if ($i -eq 1 -and -not $Compact) {
            Write-AdbRaw -Arguments @('connect', $Target) -StdOut $out -ExitCode $LASTEXITCODE
        } elseif ($text) {
            $brief = ($text -replace "`r?`n", ' / ')
            Write-Host "    $brief" -ForegroundColor DarkGray
        }

        Start-Sleep -Milliseconds 700

        if (Test-DeviceOnline $Target) {
            Write-Stamp "设备已上线：$Target" Green
            return $true
        }

        # 兜底：adb 实际登记的可能不是我们给的地址（mDNS 别名），
        # 在线列表里恰好只有一台、而且 connect 说成功了，就认它
        $online = @(Get-DeviceList | Where-Object { $_.State -eq 'device' })
        if ($online.Count -eq 1 -and $text -match 'connected to|already connected') {
            Write-Stamp "连上了（实际登记地址是 $($online[0].Serial)）" Green
            return $true
        }

        if ($script:adbTimedOut) {
            Write-Stamp "adb 20 秒没回应，这个地址多半是死的，不重试了。" Yellow
            break
        }
    }

    return $false
}

<# 连接新设备，三连尝试，一次比一次多要信息：
      第 1 次：mDNS 自动发现（会等几秒，广播有延迟）-> 列出 -> 选 -> connect
      第 2 次：手动输「连接 IP:端口」-> connect
      第 3 次：配对（pair）-> 再 connect
   返回连上的设备地址；失败返回空字符串。

   ── "手机拿远再回来就连不上" 是怎么回事 ──
   手机离开 Wi-Fi 一段时间再回来，这三样东西都会变：
     1) adb 服务里留着一条指向上次端口的死连接；
     2) adb 服务缓存着旧的 mDNS 记录（还在报老端口）；
     3) 手机重新打开无线调试后，【连接端口一定是新的】，IP 也可能被 DHCP 换掉。
   所以流程第一件事是 kill-server 把 1、2 清干净，第二件事是重新发现端口，
   而不是拿上次那个端口反复硬连 —— 那只会一直卡在"连接中"。 #>
function Connect-NewDevice {

    if (-not (Test-Interactive)) {
        Write-Host "连接流程需要交互式终端。请用 -Device 指定设备，或双击 start-watchV.cmd。" -ForegroundColor Red
        return ''
    }

    Write-Host ""
    Write-Host "--- 连接新设备 ---" -ForegroundColor Cyan
    Write-Host "手机上：设置 > 开发者选项 > 无线调试" -ForegroundColor DarkGray
    Write-Host "重开无线调试之后端口会变；一般不用重新配对，连上新端口就行。" -ForegroundColor DarkGray
    Write-Host ""

    Restart-AdbServer | Out-Null

    # 已知的【连接端口】。后面配对时要拿它做反查：
    # 如果用户把连接端口填进了配对输入框，必须当场拦下来，否则 adb pair 会一直卡着。
    $knownConnect = New-Object System.Collections.Generic.List[string]

    # ============ 第 1 次尝试：mDNS 自动发现 ============
    Write-Host ""
    Write-Host "[1/3] mDNS 扫一次 ..." -ForegroundColor White
    $mdns        = @(Get-MdnsServices)
    $connectOnes = @($mdns | Where-Object { $_.Service -eq 'connect' })

    if ($connectOnes.Count -gt 0) {

        $items  = New-Object System.Collections.Generic.List[string]
        $values = New-Object System.Collections.Generic.List[string]

        foreach ($d in $connectOnes) {
            $addr = "$($d.Host):$($d.Port)"
            if ($values.Contains($addr)) { continue }        # 同一条服务可能重复广播
            $items.Add($addr.PadRight(24) + '连接')
            $values.Add($addr)
            if (-not $knownConnect.Contains($addr)) { $knownConnect.Add($addr) }
        }

        Write-Host "  发现 $($values.Count) 个可连接地址：" -ForegroundColor DarkGray
        $idx = Read-MenuChoice -Items $items.ToArray()

        if ($idx -ge 0) {
            $target = $values[$idx]
            if (Try-Connect -Target $target) { return $target }
            Write-Stamp "第 1 次尝试失败，继续。" Yellow
        } else {
            Write-Host "  跳过 mDNS，改手动输入。" -ForegroundColor DarkGray
        }

    } elseif ($mdns.Count -gt 0) {
        Write-Stamp "只扫到配对端口，没有可连接的端口。" Yellow
        Write-Host "  配对端口不能用来连接；回手机看『无线调试』主页那个 IP:端口。" -ForegroundColor DarkGray
    } else {
        Write-Stamp "mDNS 没发现设备（手机和电脑可能不在同一网段，或者路由器挡了组播）。" Yellow
    }

    # ============ 第 2 次尝试：手动输 IP:端口 ============
    Write-Host ""
    Write-Host "[2/3] 手动输入连接地址" -ForegroundColor White
    Write-Host "  手机『无线调试』主页上那个 IP:端口（不是配对弹窗里的）" -ForegroundColor DarkGray
    Write-Host "  不想输、想直接去配对：原样回车就行。" -ForegroundColor DarkGray

    $cp     = $null
    $cpLive = $false        # 第 2 步那个端口是不是真的探通过（防止拿过期端口去误判配对端口）
    for ($round = 1; $round -le 3; $round++) {

        $answer = Read-Line -Prompt '  连接 IP:端口  ' -Prefill '192.168'
        if (-not $answer -or $answer -eq '192.168') { break }        # 直接去配对
        if (-not (Test-HostPort $answer)) {
            Write-Host "  地址不对" -ForegroundColor Yellow
            continue
        }

        $cp = Parse-HostPort -Text $answer -DefaultPort '5555'
        $portNumber = 0
        [void][int]::TryParse($cp.Port, [ref]$portNumber)
        $target = "$($cp.Host):$($cp.Port)"
        Write-Host "  → 实际输入 [$target]" -ForegroundColor DarkGray

        if (-not (Test-HostPortOpen -Address $cp.Host -Port $portNumber)) {
            Write-Stamp "$target 端口没开。" Yellow
            Write-Host "  常见原因：端口变了 / 无线调试被关了 / 手机换了 IP。" -ForegroundColor DarkGray
            Write-Host "  回手机重看一眼那个端口，再输一次。" -ForegroundColor DarkGray
            continue
        }

        $cpLive = $true
        if (Try-Connect -Target $target) { return $target }
        Write-Stamp "端口通，但 adb 没握上手（多半是没配对过，或者配对码过期了）。" Yellow
        break
    }

    # ============ 第 3 次尝试：配对 -> 再连接 ============
    Write-Host ""
    Write-Host "[3/3] 配对" -ForegroundColor White
    Write-Host "  手机上点『使用配对码配对设备』，弹窗里有 IP:端口 和 6 位码。" -ForegroundColor DarkGray
    Write-Host "  注意：弹窗里那个是【配对端口】，跟主页的连接端口不是一回事，每次重开都会变。" -ForegroundColor Yellow
    Write-Host "  必须照着当前这个弹窗抄；抄上一次的，就会一直卡在配对。" -ForegroundColor DarkGray

    $pp   = $null
    $ppOk = $false

    for ($round = 1; $round -le 3; $round++) {

        $pairAnswer = ''
        while ($true) {
            $pairAnswer = Read-Line -Prompt '  配对 IP:端口  ' -Prefill '192.168'
            if ($pairAnswer -and $pairAnswer -ne '192.168' -and (Test-HostPort $pairAnswer)) { break }
            Write-Host "  地址不对" -ForegroundColor Yellow
        }

        $pp = Parse-HostPort -Text $pairAnswer -DefaultPort '37123'
        $pairPort = 0
        [void][int]::TryParse($pp.Port, [ref]$pairPort)
        $pairAddr = "$($pp.Host):$($pp.Port)"

        # 拿连接端口去配对 = adb 会卡死：端口是开的，但对面不是配对服务，
        # 握手永远等不到回应（这正是"输入全都对，卡在配对"的一个真凶）。
        if ($cpLive -and $cp -and $cp.Host -eq $pp.Host -and $cp.Port -eq $pp.Port) {
            Write-Stamp "$pairAddr 是【连接端口】，不是配对端口。" Yellow
            Write-Host "  配对端口在『使用配对码配对设备』的弹窗里，每次都不一样。" -ForegroundColor DarkGray
            continue
        }
        if ($knownConnect.Contains($pairAddr)) {
            Write-Stamp "$pairAddr 是刚才扫到的【连接端口】，配对请填弹窗里那个。" Yellow
            continue
        }

        if (Test-HostPortOpen -Address $pp.Host -Port $pairPort -TimeoutMs 2000) {
            $ppOk = $true
            break
        }

        Write-Stamp "$pairAddr 连不上 —— 手机上的配对弹窗还开着吗？" Yellow
        Write-Host "  弹窗一关端口就没了；重开一个会换新端口，重新抄一遍。" -ForegroundColor DarkGray
    }

    if (-not $ppOk) {
        Write-Host ""
        Write-Host "配对端口一直连不上，这次先不配了。" -ForegroundColor Red
        Write-Host "  1. 确认『使用配对码配对设备』的弹窗还开着（它一关端口就没了）。" -ForegroundColor DarkGray
        Write-Host "  2. 手机和电脑是不是同一个 Wi-Fi？访客网络 / AP 隔离会直接不通。" -ForegroundColor DarkGray
        Write-Host "  3. 把无线调试关掉再打开，重新运行本脚本。" -ForegroundColor DarkGray
        return ''
    }

    $code = ''
    while (-not $code) {
        $code = Read-Line -Prompt '  配对码  '
        if (-not $code) { Write-Host "  不能空" -ForegroundColor Yellow }
    }

    $pairTarget = "$($pp.Host):$($pp.Port)"
    Write-Stamp "pair [$pairTarget] ******（最多等 20 秒）" Yellow
    $pairOut  = Invoke-Adb @('pair', $pairTarget, $code) -TimeoutSec 20
    $pairText = Get-AdbCombinedText -StdOut $pairOut
    $code = $null                    # 配对码用完即弃，不落盘
    Write-AdbRaw -Arguments @('pair', $pairTarget, '******') -StdOut $pairOut -ExitCode $LASTEXITCODE

    if ($pairText -match 'Successfully paired') {
        Write-Stamp "配对成功" Green
    } else {
        Write-Stamp "配对没成功：配对码或端口过期了（弹窗重开会同时换掉这两个）。" Yellow
        if ($script:adbTimedOut) {
            Write-Host "  adb pair 等了 20 秒没回应，已经掐掉 —— 那个端口上没有配对服务。" -ForegroundColor DarkGray
            Write-Host "  最常见的原因：填的是主页的连接端口，不是弹窗里的配对端口。" -ForegroundColor DarkGray
        }
    }

    # ---- 配对之后：端口必须重新发现 ----
    # 配对端口只能用来配对；连接端口是另一个（主页上显示的那个）。
    # 而且此刻手机已经换过端口了，第 2 步输的那个基本是旧的，
    # 所以先扫 mDNS 拿现端口，扫不到再退回去试旧端口。
    Start-Sleep -Milliseconds 1200

    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($c in @(Get-MdnsConnectTargets -HostName $pp.Host)) {
        if (-not $candidates.Contains($c)) { $candidates.Add($c) }
    }
    if ($cp -and $cp.Host -eq $pp.Host) {
        $c = "$($cp.Host):$($cp.Port)"
        if (-not $candidates.Contains($c)) { $candidates.Add($c) }
    }
    $c = "$($pp.Host):5555"
    if (-not $candidates.Contains($c)) { $candidates.Add($c) }

    Write-Host ""
    Write-Stamp "配对后重新连接（mDNS 现端口 -> 刚才输的端口 -> 5555 依次试）..." Yellow

    foreach ($c in $candidates) {
        if (Try-Connect -Target $c -Attempts 2) { return $c }
    }

    Write-Host ""
    Write-Host "三次都失败。按这个顺序排查：" -ForegroundColor Red
    Write-Host "  1. 手机和电脑是不是同一个 Wi-Fi？（访客网络 / AP 隔离会直接不通）" -ForegroundColor DarkGray
    Write-Host "  2. 手机『无线调试』还开着吗？主页的 IP:端口 和配对弹窗的端口不是一回事。" -ForegroundColor DarkGray
    Write-Host "  3. 手机 IP 变了吗？（重连 Wi-Fi 常被 DHCP 换掉，以手机屏幕上显示的为准）" -ForegroundColor DarkGray
    Write-Host "  4. 还不行就把无线调试关掉再打开，重新运行脚本（每次都会先清一遍 adb 服务）。" -ForegroundColor DarkGray
    return ''
}


# ---------------------------------------------------------------- 设备主流程
<# 优先级：
     1. -Device 显式指定               -> 直接用
     2. adb 里已有设备                 -> 方向键菜单选（含"连接新设备…"）
        没有设备 / 选了"连接新设备…"  -> 进配对引导
     3. -Setup                         -> 直接进配对引导 #>
function Resolve-Device {
    param(
        [string]$Explicit,
        [switch]$ForceSetup
    )

    # 1. 命令行显式指定
    if ($Explicit) {
        Write-Stamp "使用 -Device 指定的设备：$Explicit" Green
        return $Explicit
    }

    if (-not $ForceSetup) {

        # 每次启动先扫一次 mDNS：手机重开无线调试后连接端口会变，
        # 扫到就直接用当前端口连上；扫不到就往下走正常流程。
        Write-Stamp "扫一下 mDNS ..." DarkGray
        $discovered = @(Get-MdnsConnectTargets)
        if ($discovered.Count -gt 0) {
            foreach ($t in $discovered) {
                if (Try-Connect -Target $t -Attempts 2 -Compact) { break }
            }
        } else {
            Write-Stamp "没扫到（不代表连不上，接着看 adb 里有没有现成的）。" DarkGray
        }

        Write-Stamp "正在查看 adb 里已连接的设备 ..." DarkGray
        $all     = @(Get-DeviceList)
        $online  = @($all | Where-Object { $_.State -eq 'device' })
        $pending = @($all | Where-Object { $_.State -ne 'device' })

        if ($online.Count -gt 0) {

            # 非交互环境（管道调用等）没法画菜单，只能退化成"能用就用"
            if (-not (Test-Interactive)) {
                if ($online.Count -eq 1) {
                    Write-Stamp "（非交互环境）使用唯一在线设备：$($online[0].Serial)" Green
                    return $online[0].Serial
                }
                Write-Host "非交互环境里有多台设备，请用 -Device 指定。" -ForegroundColor Red
                $online | ForEach-Object { Write-Host "    $($_.Serial)" -ForegroundColor DarkGray }
                return ''
            }

            # 组菜单项
            $items  = New-Object System.Collections.Generic.List[string]
            $values = New-Object System.Collections.Generic.List[string]

            foreach ($d in $online) {
                $tail = $d.Model
                if (-not $tail) { $tail = Get-StateText $d.State }
                $items.Add($d.Serial.PadRight(30) + $tail)
                $values.Add($d.Serial)
            }

            # 离线 / 未授权的也列出来，但选不中（选了只给提示）
            foreach ($d in $pending) {
                $label = $d.Serial.PadRight(30) + (Get-StateText $d.State)
                $items.Add($label)
                $values.Add("__pending__$($d.Serial)|$($d.State)")
            }

            $items.Add('连接新设备…')
            $values.Add('__new__')

            Write-Host ""

            while ($true) {

                $title = "adb 里检测到 $($online.Count) 台可用设备，请选择："
                $idx = Read-MenuChoice -Items $items.ToArray() -Title $title

                if ($idx -lt 0) {
                    Write-Host "已取消。" -ForegroundColor DarkGray
                    return ''
                }

                $choice = $values[$idx]

                if ($choice -eq '__new__') { break }

                if ($choice -match '^__pending__(.+)\|(.+)$') {
                    $serial = $Matches[1]
                    $state  = $Matches[2]
                    Write-Host ""
                    Write-Host "  $serial 当前状态是「$(Get-StateText $state)」，还不能用。" -ForegroundColor Yellow
                    if ($state -eq 'unauthorized') {
                        Write-Host "  去手机上点『允许调试』（建议勾选『一律允许』），然后再选一次。" -ForegroundColor DarkGray
                    } else {
                        Write-Host "  先让它回到 device 状态（重插 USB / 重开无线调试），然后再选一次。" -ForegroundColor DarkGray
                    }
                    Write-Host ""
                    continue
                }

                return $choice
            }
        }
        else {
            Write-Host ""
            Write-Host "adb 里没有在线的设备，走一遍连接流程。" -ForegroundColor DarkGray
        }
    }

    # 2. / 3. 进配对引导
    return (Connect-NewDevice)
}


# ================================================================ 主流程

# ---------------------------------------------------------------- 0. adb 在不在
$script:AdbExe = Resolve-AdbPath

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

if (-not $script:AdbExe) {
    Write-Host ""
    Write-Host "找不到 adb 可执行文件，没法继续。" -ForegroundColor Red
    Write-Host "找过这些位置：" -ForegroundColor DarkGray
    Write-Host "    $scriptDir\adb\adb.exe" -ForegroundColor DarkGray
    Write-Host "    $scriptDir\adb.exe" -ForegroundColor DarkGray
    Write-Host "    $scriptDir\platform-tools\adb.exe" -ForegroundColor DarkGray
    Write-Host "    以及宿主机 PATH" -ForegroundColor DarkGray
    Write-Host "把 platform-tools 里的 adb.exe / AdbWinApi.dll / AdbWinUsbApi.dll 一起放进 adb\ 子目录就行。" -ForegroundColor DarkGray
    exit 1
}

# ---------------------------------------------------------------- 1. 拿到设备
Write-Host ""
Write-Host "adb 滑动热键 | Shift+↑ 上滑   Shift+↓ 下滑" -ForegroundColor Cyan

if ($script:AdbExe.ToLowerInvariant().StartsWith($scriptDir.ToLowerInvariant())) {
    Write-Stamp "adb：$script:AdbExe  (脚本自带)" Green
} else {
    Write-Stamp "adb：$script:AdbExe  (系统 PATH)" Yellow
    Write-Stamp "  想彻底不依赖宿主机，就把 adb 放进 $scriptDir\adb\ 里。" DarkGray
}

$Device = Resolve-Device -Explicit $Device -ForceSetup:$Setup
if (-not $Device) {
    Write-Host "没有可用设备，退出。" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- 2. 分辨率 -> 滑动坐标
$sizeOutput = Invoke-Adb @('-s', $Device, 'shell', 'wm', 'size')
if ($LASTEXITCODE -ne 0 -or -not $sizeOutput) {
    Write-Host "拿不到设备分辨率，adb 返回 $LASTEXITCODE。" -ForegroundColor Red
    exit 1
}

# 优先用 Override size，没有就退回 Physical size
$sizeLine = $sizeOutput |
    Where-Object { $_ -match 'Override size:\s*(\d+x\d+)' } |
    Select-Object -Last 1
if (-not $sizeLine) {
    $sizeLine = $sizeOutput |
        Where-Object { $_ -match 'Physical size:\s*(\d+x\d+)' } |
        Select-Object -Last 1
}
if ($sizeLine -notmatch '(\d+)x(\d+)') {
    Write-Host "分辨率解析失败，原始输出：" -ForegroundColor Red
    $sizeOutput | ForEach-Object { Write-Host "  $_" }
    exit 1
}

$W = [int]$Matches[1]
$H = [int]$Matches[2]

$X     = [int][math]::Floor($W / 2)          # 竖直中线
$Ynear = [int][math]::Floor($H * $NearRatio) # 屏幕靠下
$Yfar  = [int][math]::Floor($H * $FarRatio)  # 屏幕靠上
$Ymid  = [int][math]::Floor($H / 2)          # 屏幕正中（点按用）


# ---------------------------------------------------------------- 3. 滑动动作

# 计数：只活在本次会话里，关掉窗口就清零
$script:SwipeUp   = 0
$script:SwipeDown = 0
$script:TapCount  = 0
$script:SwipeFail = 0
$script:StatsRow  = -1        # 统计行所在的缓冲行号；-1 = 还没画过

<# --------------------------------------------------------- 统计行

   计数固定在【输出的最后一行】，每滑一次原地重画这一行 ——
   不新增任何输出行，屏幕刷不满，统计还一直趴在眼皮底下。

   原理：用 $script:StatsRow 记住那一行在缓冲区里的行号。
   刷新 = 把光标挪回去覆盖重写，再挪回原处（不换行，所以不占新行）。
   要打印别的内容时，先把它擦掉、让出这一行，打完再贴回最后一行。 #>
function Get-StatsText {
    $t = "adb-watchV  |  上滑 $script:SwipeUp   下滑 $script:SwipeDown   点按 $script:TapCount"
    if ($script:SwipeFail -gt 0) { $t += "   失败 $script:SwipeFail" }
    return $t
}

function Get-ConsoleWidth {
    try {
        $w = [Console]::WindowWidth
        if ($w -gt 1) { return ($w - 1) }
    } catch { }
    return 79
}

<# 原地重画统计行 #>
function Show-Stats {
    $line = (Get-StatsText).PadRight((Get-ConsoleWidth))
    try {
        if ($script:StatsRow -lt 0) {
            # 第一次：占下当前行，但【不换行】—— 让统计行本身就是最后一行，
            # 底下不留空行，光标就停在它上面。
            if ([Console]::CursorLeft -ne 0) { [Console]::WriteLine() }
            $row = [Console]::CursorTop
            [Console]::Write($line)
            $script:StatsRow = $row
        } else {
            $saved = [Console]::CursorTop
            [Console]::SetCursorPosition(0, $script:StatsRow)
            [Console]::Write($line)                      # Write 不换行，才不会多占行
            [Console]::SetCursorPosition(0, $saved)
        }
    } catch {
        # 不是真实控制台（被重定向 / 宿主不支持光标定位）就退化成普通输出
        Write-Host (Get-StatsText) -ForegroundColor DarkGray
    }
}

<# 让出统计行：擦干净、光标停在行首，并把这一行交还给下一条输出。
   调用之后正常打印，内容就落在这里，统计行则被挤到最后一行重新画。 #>
function Reset-StatsLine {
    if ($script:StatsRow -lt 0) { return }
    try {
        [Console]::SetCursorPosition(0, $script:StatsRow)
        [Console]::Write((' ' * (Get-ConsoleWidth)))
        [Console]::SetCursorPosition(0, $script:StatsRow)
    } catch { }
    $script:StatsRow = -1
}

<# 收尾汇总：先让出统计行，再打一行合计（合计本身已含上滑/下滑次数） #>
function Write-StatsSummary {
    Reset-StatsLine
    $total = $script:SwipeUp + $script:SwipeDown
    $line  = "本次共滑动 $total 次（上滑 $script:SwipeUp / 下滑 $script:SwipeDown），点按 $script:TapCount 次"
    if ($script:SwipeFail -gt 0) { $line += "，失败 $script:SwipeFail 次" }
    Write-Stamp $line Cyan
}

<# 一次滑动。
   成功时【不新增任何输出行】—— 只把最后那一行的计数改写一遍。
   只有失败才吭一声：打印前先让出统计行，打完再把统计行贴回最后一行。 #>
function Invoke-Swipe {
    param([ValidateSet('Up', 'Down')][string]$Direction)

    if ($Direction -eq 'Up') {
        $from = $Ynear; $to = $Yfar; $arrow = '↑'
    } else {
        $from = $Yfar;  $to = $Ynear; $arrow = '↓'
    }

    $arguments = @('-s', $Device, 'shell', 'input', 'swipe', "$X", "$from", "$X", "$to", "$Duration")
    $stdout    = Invoke-Adb $arguments
    $code      = $LASTEXITCODE

    if ($code -ne 0) {
        $script:SwipeFail = $script:SwipeFail + 1
        Reset-StatsLine
        Write-Stamp "$arrow 滑动失败（adb 返回 $code）" Yellow
        Write-AdbRaw -Arguments $arguments -StdOut $stdout -ExitCode $code
        Show-Stats
        return
    }

    if ($Direction -eq 'Up') {
        $script:SwipeUp = $script:SwipeUp + 1
    } else {
        $script:SwipeDown = $script:SwipeDown + 1
    }
    Show-Stats
}

<# 在屏幕正中点一下。
   和滑动同一套规矩：成功时【零输出】，只把最后那行的计数改写一遍；
   只有失败才吭一声（打印前先让出统计行，打完再贴回最后一行）。 #>
function Invoke-Tap {
    $arguments = @('-s', $Device, 'shell', 'input', 'tap', "$X", "$Ymid")
    $stdout    = Invoke-Adb $arguments
    $code      = $LASTEXITCODE

    if ($code -ne 0) {
        $script:SwipeFail = $script:SwipeFail + 1
        Reset-StatsLine
        Write-Stamp "· 点按失败（adb 返回 $code）" Yellow
        Write-AdbRaw -Arguments $arguments -StdOut $stdout -ExitCode $code
        Show-Stats
        return
    }

    $script:TapCount = $script:TapCount + 1
    Show-Stats
}


# ---------------------------------------------------------------- 4. 打印一下配置
Write-Host ""
Write-Host "wm size 原始输出：" -ForegroundColor DarkGray
$sizeOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
Write-Host ""
Write-Host "设备    : $Device"
Write-Host "分辨率  : ${W}x${H}"
Write-Host "上滑    : ($X, $Ynear) -> ($X, $Yfar)  ${Duration}ms"
Write-Host "下滑    : ($X, $Yfar)  -> ($X, $Ynear)  ${Duration}ms"
Write-Host "点按    : ($X, $Ymid)"
Write-Host ""


# ================================================================ 模式 A：全局热键
if (-not $ConsoleOnly) {

    $nativeSource = @'
using System;
using System.Runtime.InteropServices;

public static class HotKeyNative
{
    public const int  WM_HOTKEY    = 0x0312;
    public const uint MOD_SHIFT    = 0x0004;
    public const uint VK_UP        = 0x26;
    public const uint VK_DOWN      = 0x28;
    public const uint VK_SPACE     = 0x20;
    private const uint PM_REMOVE   = 0x0001;

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint   message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint   time;
        public int    ptX;
        public int    ptY;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd,
                                           uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);

    // 注册 Shift+<vk>，失败返回 false
    public static bool RegisterShiftHotKey(int id, uint vk)
    {
        return RegisterHotKey(IntPtr.Zero, id, MOD_SHIFT, vk);
    }

    public static void UnregisterHotKeyById(int id)
    {
        UnregisterHotKey(IntPtr.Zero, id);
    }

    // 非阻塞取一个热键 id；没有就返回 false（用轮询而不是阻塞 GetMessage，Ctrl+C 才响应得动）
    public static bool TryGetHotKeyId(out int id)
    {
        id = 0;
        MSG msg;
        if (PeekMessage(out msg, IntPtr.Zero, WM_HOTKEY, WM_HOTKEY, PM_REMOVE))
        {
            id = msg.wParam.ToInt32();
            return true;
        }
        return false;
    }

    // 清空热键队列：滑动是阻塞的，期间按住键攒下的重复消息必须丢掉，
    // 否则松手之后还会"惯性"滑好几屏
    public static void DrainHotKeys()
    {
        MSG msg;
        while (PeekMessage(out msg, IntPtr.Zero, WM_HOTKEY, WM_HOTKEY, PM_REMOVE)) { }
    }
}
'@

    Add-Type -TypeDefinition $nativeSource -Language CSharp

    $idUp   = 1
    $idDown = 2
    $idTap  = 3

    $okUp   = [HotKeyNative]::RegisterShiftHotKey($idUp,   [HotKeyNative]::VK_UP)
    $okDown = [HotKeyNative]::RegisterShiftHotKey($idDown, [HotKeyNative]::VK_DOWN)
    $okTap  = [HotKeyNative]::RegisterShiftHotKey($idTap,  [HotKeyNative]::VK_SPACE)

    if (-not $okUp)   { Write-Stamp "Shift+↑ 注册失败（可能被别的程序占着）" Yellow }
    if (-not $okDown) { Write-Stamp "Shift+↓ 注册失败（可能被别的程序占着）" Yellow }
    if (-not $okTap)  { Write-Stamp "Shift+空格 注册失败（多半是中文输入法占着全角/半角切换）" Yellow }
    if (-not $okUp -and -not $okDown -and -not $okTap) {
        Write-Host "三个热键都没注册上，监听没意义，退出。" -ForegroundColor Red
        exit 1
    }

    Write-Host "正在(全局)监听 Shift+↑ 上滑 / Shift+↓ 下滑 / Shift+空格 点按 ... 关窗口或 Ctrl+C 停止" -ForegroundColor Green
    Show-Stats                      # 先把统计行立起来（0 / 0）

    try {
        while ($true) {
            [int]$hotKeyId = 0
            if ([HotKeyNative]::TryGetHotKeyId([ref]$hotKeyId)) {
                if     ($hotKeyId -eq $idUp)   { Invoke-Swipe -Direction Up }
                elseif ($hotKeyId -eq $idDown) { Invoke-Swipe -Direction Down }
                elseif ($hotKeyId -eq $idTap)  { Invoke-Tap }

                [HotKeyNative]::DrainHotKeys()
            } else {
                Start-Sleep -Milliseconds 10
            }
        }
    } finally {
        if ($okUp)   { [HotKeyNative]::UnregisterHotKeyById($idUp) }
        if ($okDown) { [HotKeyNative]::UnregisterHotKeyById($idDown) }
        if ($okTap)  { [HotKeyNative]::UnregisterHotKeyById($idTap) }
        Reset-StatsLine             # 让出统计行，后面的消息按正常顺序继续往下打
        Write-Host ""
        Write-Stamp "已停止监听，热键已释放。" Cyan
        Write-StatsSummary
    }
}
# ================================================================ 模式 B：只监听本窗口
else {

    Write-Host "正在(本窗口)监听 Shift+↑ 上滑 / Shift+↓ 下滑 / Shift+空格 点按 ... 保持窗口为当前焦点，Ctrl+C 停止" -ForegroundColor Green
    Show-Stats                      # 先把统计行立起来（0 / 0）

    try {
        while ($true) {
            $key = [Console]::ReadKey($true)

            if (($key.Modifiers -band [ConsoleModifiers]::Shift) -eq 0) { continue }

            if     ($key.Key -eq [ConsoleKey]::UpArrow)   { Invoke-Swipe -Direction Up }
            elseif ($key.Key -eq [ConsoleKey]::DownArrow) { Invoke-Swipe -Direction Down }
            elseif ($key.Key -eq [ConsoleKey]::Spacebar)  { Invoke-Tap }
        }
    } finally {
        Reset-StatsLine
        Write-Host ""
        Write-Stamp "已停止监听。" Cyan
        Write-StatsSummary
    }
}
