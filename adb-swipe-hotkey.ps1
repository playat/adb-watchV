#Requires -Version 5.1
<#
.SYNOPSIS
    交互式连接设备，然后监听 Shift+↑ / Shift+↓，向 adb 设备发送"上滑 / 下滑"手势。

.DESCRIPTION
    启动后的交互流程：

      [1] 先跑 adb devices -l 看有没有已经连接的设备
          · 有 -> 用上下方向键选（回车确认），最后一项是"连接新设备…"
          · 没有 -> 直接进引导

      [2] 引导（连接新设备），三连尝试，一次比一次多要信息：
          第 1 次：mDNS 自动发现（会等几秒，因为广播有延迟）-> 列出 -> 选 -> connect
          第 2 次：手动输 IP:端口 -> connect
          第 3 次：配对 IP:端口 + 配对码 -> adb pair -> 再 connect
          IP 输入框预填了 "192.168"（内网基本都是这个开头），接着往下敲就行。

      [3] 连上之后才开始监听键盘：
          Shift + ↑   上滑（手指从屏幕下方划到上方 -> 内容往上滚）
          Shift + ↓   下滑（手指从屏幕上方划到下方 -> 内容往下滚）
          按住不放会连续滑动（一次滑动做完就补发下一次）。

    配对成功后的设备地址会存进脚本同目录的 adb-swipe.config.json，
    下次启动它会成为菜单里的默认项（直接回车即用）。
    配对码是一次性的，不会落盘。

    默认是【全局热键】：脚本窗口不在前台也照样触发，方便你盯着手机屏幕操作。
    代价是脚本运行期间，Shift+↑ / Shift+↓ 在整个系统都被本脚本吃掉
    （包括文本编辑器里的"选中到行首/行尾"这种操作）。
    不想影响其它软件就加 -ConsoleOnly：只在这个控制台窗口有焦点时生效。

    停止监听：关掉窗口，或者按 Ctrl+C。
    进程一结束，热键由系统自动释放，不会留下幽灵监听。

    adb 用的是脚本目录里自带的那个（按 .\adb\adb.exe -> .\adb.exe
    -> .\platform-tools\adb.exe 的顺序找），不依赖宿主机 PATH，
    所以整个文件夹拷到别的电脑上就能直接跑。
    都找不到才会退回宿主机 PATH 里的 adb，并给一句黄色提醒。

.EXAMPLE
    .\start-swipe.cmd                       # 双击这个，最省事
.EXAMPLE
    .\start-swipe.cmd -Setup                # 跳过设备菜单，直接进连接新设备流程
.EXAMPLE
    .\start-swipe.cmd -Device 192.168.1.100:5555 -Duration 250
.EXAMPLE
    .\start-swipe.cmd -ConsoleOnly          # 只监听本窗口，不抢系统热键
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

    # 只监听本控制台窗口，不抢系统的 Shift+↑ / Shift+↓
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

<# 统一的 adb 调用出口：
   1) 用 2>&1 把 stderr 也收进管道，按 ErrorRecord 挑出来存进 $script:adbStderr ——
      以前这里是 2>$null 直接丢掉，报错就永远看不见；
   2) 临时把 ErrorActionPreference 压成 Continue，避免 5.1 里
      "原生命令写 stderr + Stop"炸出 NativeCommandError 的老毛病；
   3) 退出码显式回写 global —— 函数里跑原生命令，$LASTEXITCODE 默认传不到调用方。
   stdout 从管道正常返回，stderr 去读 $script:adbStderr。 #>
function Invoke-Adb {
    param([string[]]$Arguments)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $script:adbStderr = @()
    try {
        & $script:AdbExe @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $script:adbStderr += $_.ToString()
            } else {
                $_
            }
        }
        $global:LASTEXITCODE = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
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


# ---------------------------------------------------------------- 配置文件
function Get-ConfigPath {
    $dir = $PSScriptRoot
    if (-not $dir) { $dir = (Get-Location).Path }
    Join-Path $dir 'adb-swipe.config.json'
}

function Read-Config {
    $path = Get-ConfigPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Stamp "配置文件读不动，忽略这次：$($_.Exception.Message)" Yellow
        $null
    }
}

function Save-Config {
    param([string]$DeviceAddress)

    try {
        [pscustomobject]@{
            device  = $DeviceAddress
            savedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        } | ConvertTo-Json | Set-Content -LiteralPath (Get-ConfigPath) -Encoding UTF8
        Write-Stamp "已记住设备，下次它会排在菜单第一项。" DarkGray
    } catch {
        Write-Stamp "配置写不进去（$($_.Exception.Message)），下次还得重输。" Yellow
    }
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

<# 自定义行输入，支持【预填文本】：提示后面先摆一段内容、光标跟在它后面，
   用户可以接着敲，也可以退格删掉重来。Read-Host 做不到这个（它没法预填）。

   键位：退格 = 删一个字符；Esc = 整个清空；回车 = 提交。
   返回去掉首尾空白的文本（预填内容保持不变时，原样返回）。 #>
function Read-Line {
    param(
        [string]$Prompt = '',
        [string]$Prefill = ''
    )

    $bs = [string][char]8      # 退格

    Write-Host $Prompt -ForegroundColor Cyan -NoNewline
    if ($Prefill) { Write-Host $Prefill -ForegroundColor DarkGray -NoNewline }
    try { [Console]::ResetColor() } catch { }

    $buffer = $Prefill

    while ($true) {
        $key = [Console]::ReadKey($true)
        $k   = $key.Key

        if ($k -eq [ConsoleKey]::Enter) {
            Write-Host ''
            return $buffer.Trim()
        }

        if ($k -eq [ConsoleKey]::Backspace) {
            if ($buffer.Length -gt 0) {
                $buffer = $buffer.Substring(0, $buffer.Length - 1)
                [Console]::Write($bs + ' ' + $bs)
            }
            continue
        }

        if ($k -eq [ConsoleKey]::Escape) {
            while ($buffer.Length -gt 0) {
                $buffer = $buffer.Substring(0, $buffer.Length - 1)
                [Console]::Write($bs + ' ' + $bs)
            }
            continue
        }

        # 只收可打印字符，方向键/功能键（KeyChar = 0）直接忽略
        $ch = $key.KeyChar
        if ($ch -and ([int]$ch -ge 32) -and ([int]$ch -ne 127)) {
            $buffer += $ch
            [Console]::Write($ch)
        }
    }
}

<# 地址格式校验：只接受 "IP" 或 "IP:端口"。
   主要防"预填了 192.168、用户又从头发了一遍"这种误操作 ——
   那样会拼成 192.168192.168.88.22 这类四不像，这里直接拦下重问。 #>
function Test-HostPort {
    param([string]$Text)
    if (-not $Text) { return $false }
    return ($Text -match '^\d{1,3}(\.\d{1,3}){3}(:\d{1,5})?$')
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


# ---------------------------------------------------------------- 配对 + 连接
<# mDNS 扫描：等手机把无线调试的 mDNS 广播发出来。
   adb mdns services 刚开无线调试时经常是空的 —— 广播有延迟，所以要等。
   扫一次，空就隔一秒重扫，最多等 MaxWaitSec 秒；期间按任意键提前结束等待。 #>
function Get-MdnsDevices {
    param([int]$MaxWaitSec = 6)

    $deadline = (Get-Date).AddSeconds($MaxWaitSec)
    $found = New-Object System.Collections.Generic.List[object]
    $waited = $false

    while ((Get-Date) -lt $deadline) {
        $raw = Invoke-Adb @('mdns', 'services')

        foreach ($line in @($raw)) {
            if (-not $line) { continue }
            if ($line -match '^\s*List of') { continue }
            # 只关心 connect 服务；pairing 服务也顺手带上端口信息
            if ($line -match '_adb-tls-(connect|pairing)\._tcp\.?\s+([0-9\.]+):(\d+)') {
                $found.Add([pscustomobject]@{
                    Service = $Matches[1]     # connect / pairing
                    Host    = $Matches[2]
                    Port    = $Matches[3]
                })
            }
        }

        if ($found.Count -gt 0) { break }

        $waited = $true
        Write-Host "  正在等 mDNS 广播 ..." -ForegroundColor DarkGray -NoNewline
        Start-Sleep -Seconds 1
        Write-Host ""
    }

    if (-not $waited) { return $found }
    return $found
}

<# 尝试连接一个地址，返回是否真的连上了。
   会先 disconnect 再 connect（清掉旧连接），然后靠 Test-DeviceOnline 判定。 #>
function Try-Connect {
    param([string]$Target)

    if (-not $Target) { return $false }

    Invoke-Adb @('disconnect', $Target) | Out-Null
    Write-Stamp "连接：adb connect $Target" Yellow
    $out  = Invoke-Adb @('connect', $Target)
    $text = Get-AdbCombinedText -StdOut $out
    Write-AdbRaw -Arguments @('connect', $Target) -StdOut $out -ExitCode $LASTEXITCODE

    Start-Sleep -Milliseconds 800

    if (Test-DeviceOnline $Target) {
        Write-Stamp "设备已上线：$Target" Green
        Save-Config -DeviceAddress $Target
        return $true
    }

    # 兜底：旧版 adb 报的地址和实际登记的可能不一样，在线列表恰好一台就认它
    $online = @(Get-DeviceList | Where-Object { $_.State -eq 'device' })
    if ($online.Count -eq 1 -and $text -match 'connected to|already connected') {
        Write-Stamp "连上了（实际登记地址是 $($online[0].Serial)）" Green
        Save-Config -DeviceAddress $online[0].Serial
        return $true
    }

    return $false
}

<# 连接新设备，三连尝试：
      第 1 次：mDNS 自动发现 -> 列出 -> 选一个 -> connect
      第 2 次：手动输 IP:端口 -> connect
      第 3 次：配对（pair）-> 再 connect
   返回连上的设备地址；失败返回空字符串。 #>
function Connect-NewDevice {

    if (-not (Test-Interactive)) {
        Write-Host "连接流程需要交互式终端。请用 -Device 指定设备，或双击 start-swipe.cmd。" -ForegroundColor Red
        return ''
    }

    Write-Host ""
    Write-Host "--- 连接新设备 ---" -ForegroundColor Cyan
    Write-Host "手机上：设置 > 开发者选项 > 无线调试" -ForegroundColor DarkGray
    Write-Host ""

    # ============ 第 1 次尝试：mDNS 自动发现 ============
    Write-Host "[1/3] mDNS 自动发现 ..." -ForegroundColor White
    $mdns = @(Get-MdnsDevices -MaxWaitSec 6)

    if ($mdns.Count -gt 0) {
        # 去重（同一台手机的 connect / pairing 两个服务都要，但按 host:port 归并）
        $items  = New-Object System.Collections.Generic.List[string]
        $values = New-Object System.Collections.Generic.List[string]

        foreach ($d in $mdns) {
            $addr = "$($d.Host):$($d.Port)"
            $svc  = if ($d.Service -eq 'pairing') { '配对' } else { '连接' }
            $items.Add($addr.PadRight(24) + $svc)
            $values.Add($addr)
        }

        Write-Host "  发现 $($mdns.Count) 个服务，选一个连接：" -ForegroundColor DarkGray
        $idx = Read-MenuChoice -Items $items.ToArray()
        if ($idx -ge 0) {
            $target = $values[$idx]
            if (Try-Connect -Target $target) { return $target }
            Write-Stamp "第 1 次尝试失败，继续。" Yellow
        } else {
            Write-Host "  跳过 mDNS，改手动输入。" -ForegroundColor DarkGray
        }
    } else {
        Write-Stamp "mDNS 没发现设备。" Yellow
    }

    # ============ 第 2 次尝试：手动输 IP:端口 ============
    Write-Host ""
    Write-Host "[2/3] 手动输入连接地址" -ForegroundColor White
    Write-Host "  手机『无线调试』主页里的 IP:端口" -ForegroundColor DarkGray

    $connAnswer = ''
    while ($true) {
        $connAnswer = Read-Line -Prompt '  连接 IP:端口  ' -Prefill '192.168'
        if ($connAnswer -and $connAnswer -ne '192.168' -and (Test-HostPort $connAnswer)) { break }
        Write-Host "  地址不对" -ForegroundColor Yellow
    }

    $cp = Parse-HostPort -Text $connAnswer -DefaultPort '5555'
    $target = "$($cp.Host):$($cp.Port)"

    if (Try-Connect -Target $target) { return $target }
    Write-Stamp "第 2 次尝试失败，需要配对。" Yellow

    # ============ 第 3 次尝试：配对 -> 再连接 ============
    Write-Host ""
    Write-Host "[3/3] 配对" -ForegroundColor White
    Write-Host "  手机上点『使用配对码配对设备』，对话框里有 IP:端口 和 6 位码" -ForegroundColor DarkGray

    # 配对地址
    $pairAnswer = ''
    while ($true) {
        $pairAnswer = Read-Line -Prompt '  配对 IP:端口  ' -Prefill '192.168'
        if ($pairAnswer -and $pairAnswer -ne '192.168' -and (Test-HostPort $pairAnswer)) { break }
        Write-Host "  地址不对" -ForegroundColor Yellow
    }
    $pp = Parse-HostPort -Text $pairAnswer -DefaultPort '37123'
    $pairTarget = "$($pp.Host):$($pp.Port)"

    # 配对码
    $code = ''
    while (-not $code) {
        $code = Read-Line -Prompt '  配对码  '
        if (-not $code) { Write-Host "  不能空" -ForegroundColor Yellow }
    }

    Write-Stamp "pair $pairTarget ******" Yellow
    $pairOut  = Invoke-Adb @('pair', $pairTarget, $code)
    $pairText = Get-AdbCombinedText -StdOut $pairOut
    $code = $null          # 配对码用完即弃

    Write-AdbRaw -Arguments @('pair', $pairTarget, '******') -StdOut $pairOut -ExitCode $LASTEXITCODE

    if ($pairText -match 'Successfully paired') {
        Write-Stamp "配对成功" Green
    } else {
        Write-Stamp "配对失败：配对码可能已过期，把对话框重开一个" Yellow
    }

    # 配对完再连一次 —— 优先试连接端口（配对端口连不上）
    $connPort = $cp.Port
    $finalTarget = "$($pp.Host):$connPort"

    Write-Host ""
    Write-Stamp "配对后重新连接 ..." Yellow
    if (Try-Connect -Target $finalTarget) { return $finalTarget }

    # 配对端口和连接端口可能不同，试一下用 pair 拿到的 host + 常见连接端口
    if (Try-Connect -Target "$($pp.Host):5555") { return "$($pp.Host):5555" }

    Write-Host ""
    Write-Host "三次都失败。同一 Wi-Fi？无线调试还开着？" -ForegroundColor Red
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

    $config     = Read-Config
    $remembered = ''
    if ($config -and $config.device) { $remembered = [string]$config.device }

    if (-not $ForceSetup) {

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
            $defaultIndex = 0

            foreach ($d in $online) {
                $tail = $d.Model
                if (-not $tail) { $tail = Get-StateText $d.State }
                $label = $d.Serial.PadRight(30) + $tail
                $items.Add($label)
                $values.Add($d.Serial)
                if ($remembered -and $d.Serial -eq $remembered) {
                    $defaultIndex = $items.Count - 1
                }
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

                Save-Config -DeviceAddress $choice
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


# ---------------------------------------------------------------- 3. 滑动动作
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

    if ($code -ne 0) { $color = 'Yellow' } else { $color = 'DarkGray' }
    Write-Stamp "$arrow swipe $X,$from -> $X,$to  ${Duration}ms" $color
    Write-AdbRaw -Arguments $arguments -StdOut $stdout -ExitCode $code
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

    $okUp   = [HotKeyNative]::RegisterShiftHotKey($idUp,   [HotKeyNative]::VK_UP)
    $okDown = [HotKeyNative]::RegisterShiftHotKey($idDown, [HotKeyNative]::VK_DOWN)

    if (-not $okUp)   { Write-Stamp "Shift+↑ 注册失败（可能被别的程序占着）" Yellow }
    if (-not $okDown) { Write-Stamp "Shift+↓ 注册失败（可能被别的程序占着）" Yellow }
    if (-not $okUp -and -not $okDown) {
        Write-Host "两个热键都没注册上，监听没意义，退出。" -ForegroundColor Red
        exit 1
    }

    Write-Host "正在(全局)监听 Shift+↑ / Shift+↓ ... 关窗口或 Ctrl+C 停止" -ForegroundColor Green

    try {
        while ($true) {
            [int]$hotKeyId = 0
            if ([HotKeyNative]::TryGetHotKeyId([ref]$hotKeyId)) {
                if     ($hotKeyId -eq $idUp)   { Invoke-Swipe -Direction Up }
                elseif ($hotKeyId -eq $idDown) { Invoke-Swipe -Direction Down }

                [HotKeyNative]::DrainHotKeys()
            } else {
                Start-Sleep -Milliseconds 10
            }
        }
    } finally {
        if ($okUp)   { [HotKeyNative]::UnregisterHotKeyById($idUp) }
        if ($okDown) { [HotKeyNative]::UnregisterHotKeyById($idDown) }
        Write-Host ""
        Write-Stamp "已停止监听，热键已释放。" Cyan
    }
}
# ================================================================ 模式 B：只监听本窗口
else {

    Write-Host "正在(本窗口)监听 Shift+↑ / Shift+↓ ... 保持窗口为当前焦点，Ctrl+C 停止" -ForegroundColor Green

    try {
        while ($true) {
            $key = [Console]::ReadKey($true)

            if (($key.Modifiers -band [ConsoleModifiers]::Shift) -eq 0) { continue }

            if     ($key.Key -eq [ConsoleKey]::UpArrow)   { Invoke-Swipe -Direction Up }
            elseif ($key.Key -eq [ConsoleKey]::DownArrow) { Invoke-Swipe -Direction Down }
        }
    } finally {
        Write-Host ""
        Write-Stamp "已停止监听。" Cyan
    }
}
