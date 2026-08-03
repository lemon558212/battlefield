@echo off
REM 飄移診斷版啟動 — 照平常玩就好，程式會在背景盯著「沒按鍵卻在動」。
REM 抓到的紀錄會寫進 logs\driftwatch.log（在專案根目錄的 logs 資料夾）。
REM 玩法：進第一章 → 部署 → 點自己的兵進第三人稱 → 走一走停下來 → 看到飄移就多停幾秒。
REM 玩完直接關掉視窗即可，然後把「有沒有飄」告訴 Claude。
cd /d "%~dp0.."
if not exist logs mkdir logs
"C:\Users\User\Desktop\Godot_v4.7.1-stable_win64.exe" --path "%~dp0." -- driftwatch > logs\driftwatch.log 2>&1
echo.
echo 紀錄已存到 logs\driftwatch.log
pause
