@echo off
SETLOCAL EnableExtensions

net session >nul 2>&1 || (
    echo 正在获取管理员权限...
    echo Set UAC = CreateObject^("Shell.Application"^) > "%TEMP%\GetAdmin.vbs"
    echo UAC.ShellExecute "%~s0", "%CD%", "", "runas", 1 >> "%TEMP%\GetAdmin.vbs"
    cscript //nologo "%TEMP%\GetAdmin.vbs"
    del "%TEMP%\GetAdmin.vbs"
    exit /b
)

set "PSScript=%~dp0update_self.ps1"

if not exist "%PSScript%" (
    echo [错误] 未找到更新脚本：%PSScript%
    echo 程序异常！
    pause
    exit /b 1
)

where powershell >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [错误] 未找到PowerShell 3.0或更高版本
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PSScript%" %*

ENDLOCAL
exit /b %ERRORLEVEL%