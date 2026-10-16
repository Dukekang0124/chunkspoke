<#
  底层触摸注入 —— 给“造句”题的拖拽（词块 -> 槽位）做可靠的自动化。
  坐标一律用「设备像素」（不是截图像素）；截图为 480 宽时请 ×1.5。

  ── 方案选型（2026-10-15 在本机 emulator-5554 / sdk_gphone64_x86_64 实测）──
  1) sendevent 直写 /dev/input/eventN：**不可用**。原因两条：
       a. shell 用户无 /dev/input/* 写权限，`adb root` 成功后仍无效果；
       b. 逐个对 event2..event12 全部 virtio_input_multi_touch_* 节点注
          DOWN/MOVE/UP（ABS_MT_TRACKING_ID + BTN_TOUCH + X/Y，量程 0..32767），
          应用均无响应 —— 这些节点没有接到主显示的输入通路。
  2) `input swipe`：可注入，但对 Flutter 拖放不稳（易被判成快速滑动/抛掷）。
  3) `input draganddrop`：**实测稳定命中**。它按“长按起拖 -> 移动 -> 落下”发事件，
     正是 Flutter Draggable/DragTarget 需要的手势形态。本工具采用此方案。
  4) `input tap`：用于普通点击（按钮、选项），稳定。

  用法：
    .\adb_touch.ps1 -Action tap  -X 70  -Y 194
    .\adb_touch.ps1 -Action drag -X1 129 -Y1 1329 -X2 157 -Y2 1035
    .\adb_touch.ps1 -Action drag -X1 129 -Y1 1329 -X2 157 -Y2 1035 -Duration 900
#>
param(
  [ValidateSet('tap','drag')][string]$Action = 'tap',
  # tap 用
  [int]$X = 0, [int]$Y = 0,
  # drag 用
  [int]$X1 = 0, [int]$Y1 = 0, [int]$X2 = 0, [int]$Y2 = 0,
  # 拖拽时长（毫秒）：太短会被判成滑动，600~900 较稳
  [int]$Duration = 700,
  [string]$Adb = "D:\tools\android-sdk\platform-tools\adb.exe",
  # 指定显示（多显示器/虚拟屏时用），默认主显示
  [string]$Display = ""
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Adb)) { throw "找不到 adb：$Adb" }

$disp = if ([string]::IsNullOrWhiteSpace($Display)) { @() } else { @('-d', $Display) }

switch ($Action) {
  'tap' {
    & $Adb shell input @disp tap $X $Y 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "input tap 失败（exit=$LASTEXITCODE）" }
    Write-Output "OK: tap ($X,$Y)"
  }
  'drag' {
    if ($X2 -eq 0 -and $Y2 -eq 0) { throw "drag 需要 -X1 -Y1 -X2 -Y2" }
    & $Adb shell input @disp draganddrop $X1 $Y1 $X2 $Y2 $Duration 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "input draganddrop 失败（exit=$LASTEXITCODE）" }
    Write-Output "OK: drag ($X1,$Y1) -> ($X2,$Y2) ${Duration}ms"
  }
}
