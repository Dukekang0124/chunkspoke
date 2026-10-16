<#
  练习页「一关自动推进」驱动 —— 把听辨 / 跟读 / 造句 串起来自动过关，
  走到「开口题」就停下并报告状态（开口要真人说话，脚本只负责把它推到眼前，
  顺便验证 Vosk 引擎加载这一步会不会崩）。

  用法：
    .\autoplay_lesson.ps1                 # 从当前练习页开始，最多 12 步
    .\autoplay_lesson.ps1 -MaxSteps 4
    .\autoplay_lesson.ps1 -Serial emulator-5554

  注意：进入练习页本身不自动化（首页列表点击坐标随分辨率变），请先手动/或用
        adb shell input tap 进到题目页再跑本脚本。
#>
param(
  [string]$Adb = "D:\tools\android-sdk\platform-tools\adb.exe",
  [string]$Serial = '',
  [int]$MaxSteps = 12,
  [int]$Settle = 1200,
  # 开口题（照读）默认停下等人；加 -SkipSay 则点「跳过」继续往下推
  [switch]$SkipSay
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui_lib.ps1')
Initialize-UiLib -Adb $Adb -Serial $Serial

$sentenceScript = Join-Path $PSScriptRoot 'autoplay_sentence.ps1'
$listenScript   = Join-Path $PSScriptRoot 'autoplay_listen.ps1'

# 判断函数只允许 return 布尔值！
# 坑：函数里用 Write-Output 打提示，会把字符串混进返回值，
#     调用处 -not (Write-IfDead) 因为拿到非空数组恒为假 —— 崩溃会被漏判。
#     所以提示一律走 Write-Host。
function Write-IfDead {
  $alive = Test-AppInForeground
  if ($alive -eq $false) {
    Write-Host ("!! 应用已不在前台 -> {0}" -f (Get-ForegroundPackage))
    Write-Host '   最近崩溃堆栈：'
    (Invoke-UiAdb @('logcat', '-b', 'crash', '-d') 2>&1 | Select-Object -Last 8) | ForEach-Object { Write-Host ("     " + $_) }
    return $false
  }
  if ($null -eq $alive) { Write-Host '   （三次都读不到前台窗口，按“未知”继续）' }
  return $true
}

$done = 0
# 注意：PowerShell 里 switch 内部的 break 只跳出 switch，不跳出外层 for，
# 所以这里统一用 $stop 标志控制整个循环。
:main for ($step = 1; $step -le $MaxSteps; $step++) {
  $stop = $false
  if (-not (Write-IfDead)) { break main }

  $snap = Get-UiNodes
  $nodes = $snap.Nodes
  $page = Get-PageInfo $nodes
  Write-Output ("── 第 {0} 步：页面 = {1}（关卡 {2} 第 {3}/{4} 句）" -f $step, $page.Kind, $page.LevelId, $page.Index, $page.Total)

  switch ($page.Kind) {
    'listen' {
      & $listenScript -Adb $Adb -Serial $Serial
      $done++
    }
    'sentence' {
      & $sentenceScript -Adb $Adb -Serial $Serial
      $done++
    }
    'echo' {
      # 跟读 / 开口 / 结果页：统一找「下一步」
      $next = @($nodes | Where-Object { $_.Desc -eq '下一步' }) | Select-Object -First 1
      if (-not $next) {
        Write-Output '   这页没有「下一步」，停在这里。屏幕文本：'
        (Get-UiTexts $nodes) | ForEach-Object { Write-Output ("     - {0}" -f $_) }
        $stop = $true
      }
      elseif (-not $next.Enabled) {
        Write-Output '   「下一步」处于禁用态（多半是开口题 / 待录音）。停在这里，观察引擎加载是否稳定：'
        (Get-UiTexts $nodes) | ForEach-Object { Write-Output ("     - {0}" -f $_) }
        Write-Output '   等 6 秒后复查进程是否还活着……'
        Start-Sleep -Seconds 6
        if (-not (Write-IfDead)) { break main }
        Write-Output '   OK：进程仍在，未见 Vosk/JNA 崩溃。'
        $stop = $true
      }
      else {
        Write-Output '   点「下一步」'
        Invoke-UiTap $next.CX $next.CY
        Start-Sleep -Milliseconds $Settle
        $done++
      }
    }
    'say' {
      # 开口题（照读）：要真人说话才能过，脚本只负责“把它推到眼前 + 验证引擎加载不崩”。
      # 注意：点「跳过」会走评分降级路径（见台账风险簇①），所以默认不点，要推流程请显式加 -SkipSay。
      Write-Output '   照读（开口题）：需要真人说话。当前屏幕文本：'
      (Get-UiTexts $nodes) | ForEach-Object { Write-Output ("     - {0}" -f $_) }
      $skip = @($nodes | Where-Object { $_.Desc -eq '跳过' }) | Select-Object -First 1
      if ($SkipSay -and $skip) {
        Write-Output '   -SkipSay：点「跳过」继续'
        Invoke-UiTap $skip.CX $skip.CY
        Start-Sleep -Milliseconds $Settle
        $done++
      }
      else {
        Write-Output '   等 6 秒确认 Vosk 引擎加载没有把进程搞崩……'
        Start-Sleep -Seconds 6
        if (-not (Write-IfDead)) { break main }
        Write-Output '   OK：进程仍在，开口题可正常进入（未点跳过）。'
        $stop = $true
      }
    }
    default {
      Write-Output '   未识别的页面，停在这里。屏幕文本：'
      (Get-UiTexts $nodes) | ForEach-Object { Write-Output ("     - {0}" -f $_) }
      $stop = $true
    }
  }
  if ($stop) { break main }
  Start-Sleep -Milliseconds 600
}

Write-Output ("结束：共完成 {0} 次交互" -f $done)
