@echo off
SETLOCAL EnableExtensions

net session >nul 2>&1 || (
echo �������ԱȨ��...
echo Set UAC = CreateObject^("Shell.Application"^) > "%TEMP%\GetAdmin.vbs"
echo UAC.ShellExecute "%~s0", "%CD%", "", "runas", 1 >> "%TEMP%\GetAdmin.vbs"
cscript //nologo "%TEMP%\GetAdmin.vbs"
del "%TEMP%\GetAdmin.vbs"
exit /b
)

set "PSScript=%~dp0logic.ps1"

if not exist "%PSScript%" (
echo [����] δ�ҵ�PowerShell�ű���%PSScript%
echo ��ȷ����װ��ʽ������
pause
exit /b 1
)

where powershell >nul 2>&1
if %ERRORLEVEL% neq 0 (
echo [���ش���] ϵͳδ��װPowerShell 3.0����߰汾
pause
exit /b 1
)

echo ���ڻ�ȡԭʼִ�в���...
for /f "delims=" %%A in ('powershell.exe -Command "Get-ExecutionPolicy -Scope LocalMachine"') do set "OriginalExecutionPolicy=%%A"
if "%OriginalExecutionPolicy%"=="" (
echo [����] �޷���ȡԭʼִ�в���
pause
exit /b 1
)

echo -------------------------------------------------------------------------------
echo                              [  ��ʼ��װ  ]                           
echo -------------------------------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%PSScript%"

echo ���ڻָ�ԭʼִ�в���...
powershell.exe -Command "Set-ExecutionPolicy %OriginalExecutionPolicy% -Scope LocalMachine -Force" >nul 2>&1

if %ERRORLEVEL% equ 0 (
echo -------------------------------------------------------------------------------
echo                              [  ��װ���  ]                           
echo -------------------------------------------------------------------------------
echo �����ִ�г���
) else (
echo -------------------------------------------------------------------------------
echo                              [  ��װʧ��  ]                           
echo -------------------------------------------------------------------------------
echo �������: %ERRORLEVEL%
)

set "timeout=100"
echo.
echo ���ڽ��� %timeout% ����Զ��ر�...
choice /C YN /T %timeout% /D Y >nul

ENDLOCAL
exit /b %ERRORLEVEL%