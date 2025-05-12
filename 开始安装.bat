@echo off
SETLOCAL EnableExtensions

net session >nul 2>&1 || (
echo 请求管理员权限...
echo Set UAC = CreateObject^("Shell.Application"^) > "%TEMP%\GetAdmin.vbs"
echo UAC.ShellExecute "%~s0", "%CD%", "", "runas", 1 >> "%TEMP%\GetAdmin.vbs"
cscript //nologo "%TEMP%\GetAdmin.vbs"
del "%TEMP%\GetAdmin.vbs"
exit /b
)

set "PSScript=%~dp0logic.ps1"

if not exist "%PSScript%" (
echo [错误] 未找到PowerShell脚本：%PSScript%
echo 请确保安装程式完整！
pause
exit /b 1
)

where powershell >nul 2>&1
if %ERRORLEVEL% neq 0 (
echo [严重错误] 系统未安装PowerShell 3.0或更高版本
pause
exit /b 1
)

echo 正在获取原始执行策略...
for /f "delims=" %%A in ('powershell.exe -Command "Get-ExecutionPolicy -Scope LocalMachine"') do set "OriginalExecutionPolicy=%%A"
if "%OriginalExecutionPolicy%"=="" (
echo [错误] 无法获取原始执行策略
pause
exit /b 1
)

echo -------------------------------------------------------------------------------
echo                              [  开始安装  ]                           
echo -------------------------------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%PSScript%"

echo 正在恢复原始执行策略...
powershell.exe -Command "Set-ExecutionPolicy %OriginalExecutionPolicy% -Scope LocalMachine -Force" >nul 2>&1

if %ERRORLEVEL% equ 0 (
echo -------------------------------------------------------------------------------
echo                              [  安装完成  ]                           
echo -------------------------------------------------------------------------------
echo 已完成执行程序！
) else (
echo -------------------------------------------------------------------------------
echo                              [  安装失败  ]                           
echo -------------------------------------------------------------------------------
echo 错误代码: %ERRORLEVEL%
)

set "timeout=100"
echo.
echo 窗口将在 %timeout% 秒后自动关闭...
choice /C YN /T %timeout% /D Y >nul

ENDLOCAL
exit /b %ERRORLEVEL%