@echo off
SETLOCAL EnableExtensions

net session >nul 2>&1 || (
    echo ���ڻ�ȡ����ԱȨ��...
    echo Set UAC = CreateObject^("Shell.Application"^) > "%TEMP%\GetAdmin.vbs"
    echo UAC.ShellExecute "%~s0", "%CD%", "", "runas", 1 >> "%TEMP%\GetAdmin.vbs"
    cscript //nologo "%TEMP%\GetAdmin.vbs"
    del "%TEMP%\GetAdmin.vbs"
    exit /b
)

set "PSScript=%~dp0update_self.ps1"

if not exist "%PSScript%" (
    echo [����] δ�ҵ����½ű���%PSScript%
    echo �����쳣��
    pause
    exit /b 1
)

where powershell >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [����] δ�ҵ�PowerShell 3.0����߰汾
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PSScript%" %*

ENDLOCAL
exit /b %ERRORLEVEL%