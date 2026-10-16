<#
  自动作答「听辨」题 —— 听句子，从 4 个选项里选出听到的那一句。

  为什么能确定答案：
    页面头部有「第 N/25 句」+ 关卡主题（如 Greetings），
    用「主题 → 关卡 id」+「N-1 → 该关第 N 个词块」就能拿到唯一正确句
    （content_pack.json → levels[].theme / levels[].chunks[].sentence.text）。
    其余 3 个选项是别的句子，属于干扰项。

  用法：
    .\autoplay_listen.ps1
    .\autoplay_listen.ps1 -DryRun
    .\autoplay_listen.ps1 -Serial emulator-5554
#>
param(
  [string]$Adb = "D:\tools\android-sdk\platform-tools\adb.exe",
  [string]$Serial = '',
  [int]$Settle = 900,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui_lib.ps1')
Initialize-UiLib -Adb $Adb -Serial $Serial

$snap = Get-UiNodes
$nodes = $snap.Nodes
$page = Get-PageInfo $nodes
if ($page.Kind -ne 'listen') {
  throw ("当前页面不是听辨题（识别为 {0}）。屏幕文本：{1}" -f $page.Kind, ((Get-UiTexts $nodes) -join ' | '))
}
if (-not $page.LevelId -or $page.Index -lt 1) {
  throw ("读不到关卡/句序（LevelId='{0}' Index={1}）" -f $page.LevelId, $page.Index)
}

$chunk = Get-ChunkSentence $page.LevelId $page.Index
if (-not $chunk) { throw ("题库里没有关卡 {0} 的第 {1} 句" -f $page.LevelId, $page.Index) }
$target = $chunk.sentence.text
Write-Output ("关卡 {0}（{1}）第 {2} 句   正确选项：{3}" -f $page.LevelId, $page.Theme, $page.Index, $target)

# 选项 = 与正确句同在一个「选项带」里的文本节点：直接按文本精确匹配最稳
$opt = @($nodes | Where-Object { $_.Desc -eq $target }) | Select-Object -First 1
if (-not $opt) {
  $visible = @($nodes | Where-Object { $_.Desc } | ForEach-Object { $_.Desc }) -join ' | '
  throw ("选项里找不到「{0}」。屏幕文本：{1}" -f $target, $visible)
}

Write-Output ("点击 ({0},{1})  {2}" -f $opt.CX, $opt.CY, $target)
if ($DryRun) { Write-Output '（DryRun，未发事件）'; return }

Invoke-UiTap $opt.CX $opt.CY
Start-Sleep -Milliseconds $Settle

$fg = Get-ForegroundPackage
if ($fg -and $fg -notmatch 'chunkspoke_flutter') { Write-Output ("警告：应用已不在前台 -> {0}" -f $fg); return }
$snap = Get-UiNodes
$after = Get-PageInfo $snap.Nodes
Write-Output ("作答后页面：{0}" -f $after.Kind)
