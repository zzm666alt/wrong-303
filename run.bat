@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo ============================================
echo   校园电动车管理平台 - Windows 一键启动
echo ============================================

REM 1. 检查 Python
where python >nul 2>nul
if errorlevel 1 (
    echo [错误] 未检测到 Python，请先安装 Python 3.10 或更高版本，
    echo        安装时勾选 "Add Python to PATH"，然后重新运行本脚本。
    pause
    exit /b 1
)

REM 2. 创建虚拟环境
if not exist ".venv\Scripts\python.exe" (
    echo [初始化] 创建虚拟环境 .venv ...
    python -m venv .venv
)

REM 3. 安装依赖
echo [初始化] 检查并安装依赖包 ...
".venv\Scripts\python.exe" -m pip install --upgrade pip
".venv\Scripts\python.exe" -m pip install -r requirements.txt

REM 4. 生成 .env 配置模板
if not exist ".env" (
    copy ".env.example" ".env" >nul
    echo [提示] 已根据 .env.example 生成 .env 文件。
    echo        请先填写 SQL_PASSWORD 等数据库连接信息，保存后重新运行本脚本。
    notepad ".env"
    pause
    exit /b 1
)

REM 5. 环境预检
".venv\Scripts\python.exe" preflight.py
if errorlevel 1 (
    echo [警告] 环境预检未完全通过，请按上面的提示检查后重试。
    pause
    exit /b 1
)

REM 6. 启动 Flask 服务
echo [启动] 服务运行在 http://127.0.0.1:5000 ，按 Ctrl+C 停止。
".venv\Scripts\python.exe" app.py
pause
