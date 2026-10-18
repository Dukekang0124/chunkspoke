@echo off
chcp 65001 >nul
setlocal
rem 发布脚本启动器：双击即可运行，自动切到 chunkspoke-flutter 目录
rem （不依赖你手打中文路径；cmd 的 codepage 处理中文路径经常失败）
rem 用法：
rem   publish.bat              正式发布（会要求粘贴 GitHub Token）
rem   publish.bat --dry-run    只做本地校验，不上传
rem 额外参数会原样传给 publish_release.py，例如：
rem   publish.bat --mirror-url https://cdn.example.com/chunkspoke-latest.apk

cd /d "%~dp0.." || (
  echo [错误] 无法进入脚本所在目录：%~dp0..
  if not defined NOPAUSE pause
  exit /b 1
)

echo 工作目录：%CD%
echo.

if /i "%~1"=="--dry-run" goto run
if defined GITHUB_TOKEN goto run

echo 需要 GitHub Token（classic PAT 勾 repo；细粒度 PAT 勾 Contents 读写）。
echo 没有的话去 https://github.com/settings/tokens 生成，粘贴后回车。
echo 注意：输入内容会显示在屏幕上。
set /p GITHUB_TOKEN=Token: 
echo.

:run
python tools\publish_release.py --apk ..\chunkspoke-v1.2.8-arm64.apk %*
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo [退出码 %RC%] 发布未完成，请把上面的日志发我。
if not defined NOPAUSE pause
endlocal & exit /b %RC%
