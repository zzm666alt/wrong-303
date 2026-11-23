"""启动前环境预检：Python 版本、依赖包、ODBC 驱动与数据库连接。

脚本会读取 .env 中的数据库配置，逐项检查并给出可操作的提示；
任一硬性检查不通过时返回非零退出码，便于启动脚本中断流程。
"""
from __future__ import annotations

import os
import sys


def main() -> int:
    # 1. Python 版本
    if sys.version_info < (3, 10):
        print("[不通过] Python 版本需 3.10 或更高，当前为 " + sys.version.split()[0])
        return 1
    print("[通过] Python 版本 " + sys.version.split()[0])

    # 2. 依赖包
    missing = []
    for module, package in [
        ("flask", "Flask"),
        ("pyodbc", "pyodbc"),
        ("dotenv", "python-dotenv"),
    ]:
        try:
            __import__(module)
            print(f"[通过] 依赖 {package} 已安装")
        except ImportError:
            missing.append(package)
            print(f"[不通过] 缺少依赖 {package}")
    if missing:
        print("请执行：python -m pip install -r requirements.txt")
        return 1

    # 3. 读取 .env 配置
    from dotenv import load_dotenv

    load_dotenv()
    server = os.getenv("SQL_SERVER", "localhost")
    database = os.getenv("SQL_DATABASE", "CampusEVPlatformDB")
    driver = os.getenv("SQL_DRIVER", "ODBC Driver 18 for SQL Server")
    mode = os.getenv("SQL_AUTH_MODE", "sql")
    print(f"[配置] 服务器={server} 数据库={database} 驱动={driver} 认证={mode}")

    # 4. ODBC 驱动检测
    import pyodbc

    installed = pyodbc.drivers()
    if driver not in installed:
        print(f"[警告] 未检测到“{driver}”")
        print("       已安装驱动：" + (", ".join(installed) if installed else "无"))
        print("       可安装 ODBC Driver 18，或把 .env 中 SQL_DRIVER 改为已安装的 Driver 17 名称。")
    else:
        print("[通过] 已检测到 ODBC 驱动 " + driver)

    # 5. 数据库连接测试
    try:
        from app import connect_db

        conn = connect_db()
        cur = conn.cursor()
        cur.execute("SELECT 1")
        cur.fetchone()
        conn.close()
        print("[通过] 数据库连接成功")
        return 0
    except Exception as exc:  # noqa: BLE001 —— 预检只需展示首行错误并给出指引
        first_line = str(exc).splitlines()[0] if str(exc) else "未知错误"
        print("[不通过] 数据库连接失败：" + first_line)
        print("       请确认：SQL Server 服务已启动；已运行初始化 SQL 脚本；")
        print("       .env 中的账号密码与 setup_web_login.sql 设置一致。")
        return 1


if __name__ == "__main__":
    sys.exit(main())
