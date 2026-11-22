@echo off
chcp 65001 >nul
setlocal

set "SSH_USER=root"
set "SCRIPT_NAME=nginx_version_inventory.sh"
set "WORK_DIR=%~dp0"
set "SCRIPT_FULL=%WORK_DIR%%SCRIPT_NAME%"

if not exist "%SCRIPT_FULL%" goto NO_SH

:InputName
set "USER_NAME="
set /p USER_NAME=请输入姓名:
if "%USER_NAME%"=="" goto InputName

:InputIP
set "SERVER_IP="
set /p SERVER_IP=请输入服务器IP:
if "%SERVER_IP%"=="" goto InputIP

set "OUT_CSV=%WORK_DIR%%USER_NAME%_%SERVER_IP%.csv"

:: ========== 拆掉if括号，用goto，根治 : was unexpected ==========
if not exist "%OUT_CSV%" goto READY_RUN
set "CHOICE="
set /p CHOICE=文件 %USER_NAME%_%SERVER_IP%.csv 已存在，是否覆盖？(Y/N):
if /i "%CHOICE%"=="Y" goto READY_RUN
echo 已取消扫描
pause
goto END

:READY_RUN
echo 正在检查ssh...
where ssh >nul 2>&1
if errorlevel 1 goto NO_SSH

echo 开始执行：ssh %SSH_USER%@%SERVER_IP%
ssh %SSH_USER%@%SERVER_IP% "LOGIN_IP=%SERVER_IP% CSV_STDOUT=1 bash -s" < "%SCRIPT_FULL%" > "%OUT_CSV%"
set ret=%errorlevel%
echo ssh返回码：%ret%
if %ret% neq 0 goto SSH_FAIL

echo 成功，输出文件：%OUT_CSV%
pause
goto END

:NO_SH
echo [错误] 找不到 %SCRIPT_NAME%
pause
goto END

:NO_SSH
echo [错误] 本机没有ssh命令，请安装OpenSSH客户端
pause
goto END

:SSH_FAIL
echo ======================================
echo SSH执行失败！
echo 常见原因：密码错误、网络不通、sh脚本带BOM/CRLF换行
echo ======================================
if exist "%OUT_CSV%" del /q "%OUT_CSV%"
pause
goto END

:END
endlocal
