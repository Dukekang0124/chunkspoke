<#
  自动完成「造句」题 —— 把底部词块拖进上方槽位。

  做法：
    1. ui_lib 取语义树（content-desc = 文本，bounds = 坐标）——不用任何写死的分辨率。
    2. 用屏幕上的中文题干去 assets/content_pack.json 匹配句子，取 sentence.slots 顺序为答案；
       若该句带 swapSlotIndex（换空槽位的词），就在 swapOptions 里挑实际出现在屏幕上的那个。
    3. 逐个 `input draganddrop` 把对应词块拖进「第一个空槽位」。
       **每拖一次都重新 dump** —— 词块移出托盘后整排会重排，一次性算好坐标的脚本必然错位。

  用法：
    .\autoplay_sentence.ps1                 # 当前页面须是造句题
    .\autoplay_sentence.ps1 -DryRun         # 只打印拖拽计划
    .\autoplay_sentence.ps1 -MaxDrags 5     # 分步：只拖 5 块
    .\autoplay_sentence.ps1 -Serial emulator-5554   # 多设备时指定
#>
param(
  [string]$Adb = "D:\tools\android-sdk\platform-tools\adb.exe",
  [string]$Serial = '',
  [int]$Duration = 700,
  # 最多拖几次（0 = 不限）
  [int]$MaxDrags = 0,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui_lib.ps1')
Initialize-UiLib -Adb $Adb -Serial $Serial

$ph = Get-UiPlaceholder

# ---- 1. 读页面 ---------------------------------------------------------------
$snap = Get-UiNodes
$nodes = $snap.Nodes
$page = Get-PageInfo $nodes
if ($page.Kind -ne 'sentence') {
  throw ("当前页面不是造句题（识别为 {0}）。屏幕文本：{1}" -f $page.Kind, ((Get-UiTexts $nodes) -join ' | '))
}
$prompt = $page.Prompt
if (-not $prompt) { throw '读不到中文题干（屏幕上没有匹配题库 meaningCN 的文本）' }

$trayTop = Get-TrayTop $nodes
$tray = Get-TrayChips $nodes $trayTop
$trayTexts = @($tray | ForEach-Object { $_.Desc })
$onScreen = Get-UiTexts $nodes
Write-Output ("题干：{0}    托盘分界 y>={1}    托盘词块：{2}" -f $prompt, $trayTop, ($trayTexts -join ' / '))

# ---- 2. 选答案（判据用屏幕上所有文本：已入槽的词会离开托盘，但仍是答案词） ----
$answer = $null
foreach ($cand in (Get-ChunksByMeaning $prompt)) {
  $texts = @($cand.Chunk.sentence.slots | ForEach-Object { $_.text })
  if ($null -ne $cand.Chunk.sentence.swapSlotIndex) {
    $si = [int]$cand.Chunk.sentence.swapSlotIndex
    if ($onScreen -notcontains $texts[$si]) {
      $alt = @($cand.Chunk.sentence.swapOptions) | Where-Object { $onScreen -contains $_ } | Select-Object -First 1
      if ($alt) { $texts[$si] = $alt }
    }
  }
  $missing = @($texts | Where-Object { $onScreen -notcontains $_ })
  if ($missing.Count -eq 0) { $answer = $texts; break }
  Write-Verbose ("候选 {0} 缺词块：{1}" -f $cand.Chunk.id, ($missing -join ','))
}
if (-not $answer) { throw "题库里找不到与当前屏幕吻合的答案，题干=$prompt" }
$total = $answer.Count
Write-Output ("答案（{0} 词）：{1}" -f $total, ($answer -join ' '))

# ---- 3. 逐个拖拽 --------------------------------------------------------------
$dragged = 0
for ($guard = 0; $guard -lt $total + 3; $guard++) {
  if ($MaxDrags -gt 0 -and $dragged -ge $MaxDrags) { Write-Output "（已到 -MaxDrags $MaxDrags，停止）"; break }

  $snap = Get-UiNodes
  $nodes = $snap.Nodes
  $slots = @($nodes | Where-Object { $_.Desc -eq $ph } | Sort-Object T, L)
  if ($slots.Count -eq 0) { break }                     # 已填满

  $trayTop = Get-TrayTop $nodes
  $target = $slots[0]
  # 空槽位按左到右、上到下补齐：第 k 个空槽位对应答案第 (总词数 - 剩余空槽数) 个词
  $idx = $total - $slots.Count
  if ($idx -lt 0 -or $idx -ge $total) { throw "槽位数与答案词数不符（空槽=$($slots.Count) 答案=$total）" }
  $word = $answer[$idx]

  $chip = @($nodes | Where-Object { $_.Desc -eq $word -and $_.T -ge $trayTop } | Select-Object -First 1)
  if (-not $chip) { throw "托盘里找不到词块「$word」（可能已被拖入槽位或文案不一致）" }

  Write-Output ("[{0}/{1}] {2}  ({3},{4}) -> ({5},{6})" -f ($idx + 1), $total, $word, $chip.CX, $chip.CY, $target.CX, $target.CY)
  if ($DryRun) { $dragged++; continue }
  Invoke-UiDrag $chip.CX $chip.CY $target.CX $target.CY -Duration $Duration
  $dragged++
}

# ---- 4. 校验 ------------------------------------------------------------------
if ($DryRun) { Write-Output '（DryRun，未发事件）'; return }

if ((Test-AppInForeground) -eq $false) {
  Write-Output ("警告：应用已不在前台 -> {0}" -f (Get-ForegroundPackage))
  Write-Output '（多半是崩溃/被回收；用 tools\crash_capture.ps1 或 `adb logcat -b crash -d` 取堆栈）'
  return   # 不用 exit：本脚本会被 autoplay_lesson 用 & 调用，exit 有连带退出调用方的风险
}
$snap = Get-UiNodes
$left = @($snap.Nodes | Where-Object { $_.Desc -eq $ph }).Count
if ($left -gt 0) {
  if ($MaxDrags -gt 0) { Write-Output "已拖 $dragged 次，还剩 $left 个空槽位（-MaxDrags 提前停止）"; return }
  throw "仍有 $left 个空槽位未填满"
}
Write-Output ("完成：{0} 个槽位已填满 -> {1}" -f $total, ($answer -join ' '))
