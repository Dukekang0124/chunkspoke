<#
  ui_lib.ps1 —— 公共库（被其它脚本 dot-source，不要直接运行）

  提供三件事：
    1. 读 Flutter 语义树：uiautomator dump → 每个节点的「文本 + 屏幕矩形」
    2. 手势注入：tap / drag（走 input draganddrop，见 adb_touch.ps1 注释里的选型结论）
    3. 题库索引：把 assets/content_pack.json 变成「题干 → 句子」「关卡 → 词块」的查找表

  设计要点：
    - 坐标一律用设备像素，由语义树 bounds 直接给出，因此**不写死任何分辨率**。
    - 托盘区不写死 y 阈值：托盘一定在「最后一个空槽位」下方，用空槽位的
      最大下边界 + 余量自动推出分界线。

  用法：
    . "$PSScriptRoot\ui_lib.ps1"
    Initialize-UiLib -Adb $Adb -Serial $Serial
    $nodes = Get-UiNodes
#>

$script:UiAdb      = 'D:\tools\android-sdk\platform-tools\adb.exe'
$script:UiSerial   = ''
$script:UiDumpFile = Join-Path $env:TEMP '_ui_dump.xml'
$script:UiPack     = ''
$script:UiData     = $null
$script:UiPlaceholder = '—'

function Initialize-UiLib {
  param(
    [string]$Adb = '',
    [string]$Serial = '',
    [string]$DumpFile = '',
    [string]$Pack = '',
    [string]$Placeholder = ''
  )
  if ($Adb) { $script:UiAdb = $Adb }
  if (-not (Test-Path $script:UiAdb)) { throw "找不到 adb：$($script:UiAdb)" }
  $script:UiSerial = $Serial
  if ($DumpFile) { $script:UiDumpFile = $DumpFile }
  if ($Placeholder) { $script:UiPlaceholder = $Placeholder }
  if (-not $Pack) { $Pack = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\content_pack.json' }
  if (-not (Test-Path $Pack)) { throw "找不到题库：$Pack" }
  $script:UiPack = $Pack
  $script:UiData = $null
}

function Get-UiPlaceholder { $script:UiPlaceholder }

function Invoke-UiAdb {
  param([string[]]$Cmd)
  $a = @()
  if ($script:UiSerial) { $a += @('-s', $script:UiSerial) }
  $a += $Cmd
  & $script:UiAdb @a
}

# 当前前台窗口的包名（判断应用是否还活着）
function Get-ForegroundPackage {
  $line = (Invoke-UiAdb @('shell', 'dumpsys', 'window') 2>&1 | Select-String -Pattern 'mCurrentFocus' | Select-Object -First 1)
  if (-not $line) { return '' }
  $s = $line.ToString()
  if ($s -match 'u0\s+([\w\.]+)/') { return $Matches[1] }
  return $s.Trim()
}

# dump 语义树 → 节点数组（Desc / 矩形 / 中心点）
function Get-UiNodes {
  Invoke-UiAdb @('shell', 'uiautomator', 'dump', '/sdcard/_ui.xml') | Out-Null
  Invoke-UiAdb @('pull', '/sdcard/_ui.xml', $script:UiDumpFile) | Out-Null
  if (-not (Test-Path $script:UiDumpFile)) { throw 'uiautomator dump 失败：没有拿到 xml' }
  $doc = New-Object System.Xml.XmlDocument
  $doc.Load($script:UiDumpFile)
  $screenW = 0; $screenH = 0
  $root = $doc.DocumentElement.SelectSingleNode('node')
  if ($root) {
    $rb = $root.GetAttribute('bounds')
    if ($rb -match '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$') { $screenW = [int]$Matches[3]; $screenH = [int]$Matches[4] }
  }
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($n in $doc.SelectNodes('//node')) {
    $b = $n.GetAttribute('bounds')
    if ($b -notmatch '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$') { continue }
    $l = [int]$Matches[1]; $t = [int]$Matches[2]; $r = [int]$Matches[3]; $bo = [int]$Matches[4]
    $list.Add([pscustomobject]@{
      Desc = $n.GetAttribute('content-desc')
      Enabled = ($n.GetAttribute('enabled') -ne 'false')
      L = $l; T = $t; R = $r; B = $bo
      CX = [int](($l + $r) / 2); CY = [int](($t + $bo) / 2)
    })
  }
  return [pscustomobject]@{ Nodes = $list; ScreenW = $screenW; ScreenH = $screenH }
}

# 屏幕上的文本清单。多行 desc（Flutter 把标题+副标题塞一个节点，如 "打招呼\nGreetings"）
# 按行拆开，这样「关卡主题」也能单独匹配到。
function Get-UiTexts($nodes) {
  $out = @()
  foreach ($n in ($nodes | Where-Object { $_.Desc } | Sort-Object T, L)) {
    foreach ($line in ($n.Desc -split "\r?\n")) {
      $s = $line.Trim()
      if ($s) { $out += $s }
    }
  }
  return $out
}

# 托盘分界线：取所有空槽位占位符的最大下边界 + 余量（不写死分辨率）
function Get-TrayTop($nodes, [int]$Margin = 20) {
  $ph = @($nodes | Where-Object { $_.Desc -eq $script:UiPlaceholder })
  if ($ph.Count -eq 0) { return 0 }
  $maxB = ($ph | Measure-Object -Property B -Maximum).Maximum
  return ([int]$maxB + $Margin)
}

# 托盘里的词块（在分界线以下、非空占位符的文本节点）
function Get-TrayChips($nodes, [int]$TrayTop) {
  return @($nodes | Where-Object { $_.Desc -and $_.Desc -ne $script:UiPlaceholder -and $_.T -ge $TrayTop })
}

function Get-PackData {
  if ($script:UiData) { return $script:UiData }
  $json = [System.IO.File]::ReadAllText($script:UiPack, [System.Text.Encoding]::UTF8)
  $script:UiData = $json | ConvertFrom-Json
  return $script:UiData
}

# 题干（中文）→ 候选句子列表
function Get-ChunksByMeaning([string]$meaning) {
  $out = @()
  foreach ($lv in (Get-PackData).levels) {
    foreach ($ch in $lv.chunks) {
      if ($ch.meaningCN -eq $meaning) { $out += [pscustomobject]@{ Level = $lv.id; Theme = $lv.theme; Chunk = $ch } }
    }
  }
  return $out
}

function Get-LevelByTheme([string]$theme) {
  foreach ($lv in (Get-PackData).levels) { if ($lv.theme -eq $theme) { return $lv } }
  return $null
}

# 页面识别：返回 Kind / 关卡 / 句序 / 题干
#   sentence = 造句（拖拽题）  listen = 听辨（选择题）  say = 照读（开口题）
#   echo = 跟读/结果等带“下一步”的过渡页
#
# 坑：答题后的结果页/跟读页头部**仍然标着「听辨」或「造句」**，只按头部标签判断会把
# 结果页当成题目页、反复作答。所以必须先看“交互控件特征”：
#   有「跟着读一遍 / 点一下播放，跟着说」 → 跟读结果页
#   有「听句子，选出你听到的那一句」     → 听辨题目页
#   还存在空槽位占位符                   → 造句题目页
#   只剩「下一步」                       → 通用结果/推进页
function Get-PageInfo($nodes) {
  $texts = Get-UiTexts $nodes
  $info = [pscustomobject]@{
    Kind = 'unknown'; LevelId = ''; Theme = ''; Index = 0; Total = 0; Prompt = ''; Texts = $texts
  }
  $ph = Get-UiPlaceholder
  $hasPlaceholder = @($nodes | Where-Object { $_.Desc -eq $ph }).Count -gt 0
  $isReadAlong = ($texts -contains '跟着读一遍') -or ($texts -contains '点一下播放，跟着说')

  if ($isReadAlong) { $info.Kind = 'echo' }
  elseif ($texts -contains '照读' -or $texts -contains '开口说出来') { $info.Kind = 'say' }  # 开口题（录音 + Vosk 评测）
  elseif ($texts -contains '听句子，选出你听到的那一句') { $info.Kind = 'listen' }
  elseif ($hasPlaceholder) { $info.Kind = 'sentence' }
  elseif ($texts -contains '下一步') { $info.Kind = 'echo' }
  elseif ($texts -contains '造句') { $info.Kind = 'sentence' }
  elseif ($texts -contains '听辨') { $info.Kind = 'listen' }

  $m = $texts | Where-Object { $_ -match '^第\s*(\d+)\s*/\s*(\d+)\s*句$' } | Select-Object -First 1
  if ($m -and $m -match '^第\s*(\d+)\s*/\s*(\d+)\s*句$') {
    $info.Index = [int]$Matches[1]; $info.Total = [int]$Matches[2]
  }
  foreach ($lv in (Get-PackData).levels) {
    if ($lv.theme -and ($texts -contains $lv.theme)) { $info.LevelId = $lv.id; $info.Theme = $lv.theme; break }
  }
  # 题干：屏幕上出现的、题库里存在的 meaningCN
  $meanings = @{}
  foreach ($lv in (Get-PackData).levels) { foreach ($ch in $lv.chunks) { if ($ch.meaningCN) { $meanings[$ch.meaningCN] = $true } } }
  $p = $texts | Where-Object { $meanings.ContainsKey($_) } | Select-Object -First 1
  if ($p) { $info.Prompt = $p }
  return $info
}

# 本关第 Index 句的标准答案（听辨选择题靠它定位正确选项）
function Get-ChunkSentence([string]$levelId, [int]$index) {
  foreach ($lv in (Get-PackData).levels) {
    if ($lv.id -ne $levelId) { continue }
    if ($index -lt 1 -or $index -gt @($lv.chunks).Count) { return $null }
    return @($lv.chunks)[$index - 1]
  }
  return $null
}

# 目标应用是否还在前台。返回 $true / $false / $null（三次都读不到，视为未知）
# 坑：崩溃瞬间 dumpsys window 可能读不到 mCurrentFocus，若把「读不到」当「还活着」
# 就会漏判崩溃 —— 所以读不到要重试，而不是直接放行。
function Test-AppInForeground([string]$PackageLike = 'chunkspoke_flutter', [int]$Retry = 3) {
  for ($i = 0; $i -lt $Retry; $i++) {
    $fg = Get-ForegroundPackage
    if ($fg -and $fg -match $PackageLike) { return $true }
    if ($fg) { return $false }
    Start-Sleep -Milliseconds 400
  }
  return $null
}

function Invoke-UiTap([int]$X, [int]$Y) {
  Invoke-UiAdb @('shell', 'input', 'tap', "$X", "$Y") | Out-Null
}

# 拖拽：用 input draganddrop（长按起拖→移动→落下），Flutter 拖放要的正是这个手势形态
function Invoke-UiDrag([int]$X1, [int]$Y1, [int]$X2, [int]$Y2, [int]$Duration = 700, [int]$Settle = 500) {
  Invoke-UiAdb @('shell', 'input', 'draganddrop', "$X1", "$Y1", "$X2", "$Y2", "$Duration") | Out-Null
  if ($Settle -gt 0) { Start-Sleep -Milliseconds $Settle }
}
