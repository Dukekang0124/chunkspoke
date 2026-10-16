# 一键抓取崩溃堆栈（真机）：手机插 USB + 开启 USB 调试后运行本脚本
# 产出：桌面 crash_stack.txt（系统 crash 缓冲区 + flutter 日志）
$adb = "D:\tools\android-sdk\platform-tools\adb.exe"
$out = "$env:USERPROFILE\Desktop\crash_stack.txt"
& $adb devices
& $adb logcat -b crash -d | Out-File -FilePath $out -Encoding utf8
& $adb logcat -d -s flutter | Out-File -FilePath $out -Append -Encoding utf8
Write-Output "已保存到 $out（请把该文件发给开发）"
