#!/usr/bin/env bash
# 校园电动车管理平台 - Linux / macOS 启动脚本
set -euo pipefail
cd "$(dirname "$0")"

echo "============================================"
echo "  校园电动车管理平台 - 启动脚本"
echo "============================================"

if ! command -v python3 >/dev/null 2>&1; then
    echo "[错误] 未检测到 python3，请先安装 Python 3.10 或更高版本。"
    exit 1
fi

if [ ! -d ".venv" ]; then
    echo "[初始化] 创建虚拟环境 .venv ..."
    python3 -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate

echo "[初始化] 检查并安装依赖包 ..."
pip install --upgrade pip
pip install -r requirements.txt

if [ ! -f ".env" ]; then
    cp .env.example .env
    echo "[提示] 已根据 .env.example 生成 .env 文件，请填写数据库连接信息后重新运行。"
    exit 1
fi

python preflight.py
python app.py
