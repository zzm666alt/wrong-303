"""校园电动车管理平台：Flask + SQL Server（课程设计演示版）。

所有业务读写都调用数据库存储过程；不允许网页直接更新学生信息表。
安装 requirements.txt 后，以 python app.py 启动。
"""
from __future__ import annotations

import hmac
import logging
import os
import secrets
import threading
import time
from functools import wraps

from dotenv import load_dotenv
from flask import (
    Flask, abort, flash, g, redirect, render_template,
    request, session, url_for,
)
import pyodbc

load_dotenv()

app = Flask(__name__)
app.config.update(
    SECRET_KEY=os.getenv("FLASK_SECRET_KEY") or secrets.token_hex(32),
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=os.getenv("COOKIE_SECURE", "no").lower() == "yes",
    MAX_CONTENT_LENGTH=1024 * 50,
)
logging.basicConfig(level=logging.INFO)

# 教学项目：单进程内存会话；数据库登录令牌永远不放在浏览器 cookie 中。
# 正式部署为多进程时，请替换为共享服务器端会话存储（如 Redis）。
_sessions = {}
_sessions_lock = threading.RLock()
SESSION_SECONDS = 2 * 60 * 60

BUSINESS_ERRORS = (
    "账号或密码错误", "登录已过期", "尚未登录", "密码不正确",
    "原密码不正确", "新密码至少8位", "无管理员权限",
    "没有管理员", "没有管理员操作权限", "没有管理员查询权限",
    "学生未登录", "需要先修改初始密码", "需要先修改密码",
    "重置密码至少为6位", "不存在该学生账号",
    "无法唯一定位学生", "牌号和型号不能为空",
    "新牌号和新型号不能为空", "未找到该学生名下",
)


def _odbc_value(value):
    """正确引用含特殊字符的 ODBC 连接配置。"""
    return "{" + str(value).replace("}", "}}") + "}"


def connect_db():
    server = os.getenv("SQL_SERVER", r"localhost")
    database = os.getenv("SQL_DATABASE", "CampusEVPlatformDB")
    driver = os.getenv("SQL_DRIVER", "ODBC Driver 18 for SQL Server")
    mode = os.getenv("SQL_AUTH_MODE", "sql").lower()
    parts = [
        f"DRIVER={_odbc_value(driver)}",
        f"SERVER={_odbc_value(server)}",
        f"DATABASE={_odbc_value(database)}",
        f"Encrypt={os.getenv('SQL_ENCRYPT', 'yes')}",
        f"TrustServerCertificate={os.getenv('SQL_TRUST_SERVER_CERTIFICATE', 'yes')}",
        "Connection Timeout=5",
        "Application Name=CampusEVWebDemo",
    ]
    if mode == "windows":
        parts.append("Trusted_Connection=yes")
    else:
        parts.append(f"UID={_odbc_value(os.getenv('SQL_USERNAME', 'campus_ev_web'))}")
        parts.append(f"PWD={_odbc_value(os.getenv('SQL_PASSWORD', ''))}")
    return pyodbc.connect(";".join(parts), timeout=5)


def run_sql(sql, *params):
    """执行参数化 SQL 并取出所有结果集；数据库角色只允许调用存储过程。"""
    conn = connect_db()
    try:
        cur = conn.cursor()
        cur.execute(sql, *params)
        result_sets = []
        while True:
            if cur.description is not None:
                columns = [c[0] for c in cur.description]
                rows = [dict(zip(columns, row)) for row in cur.fetchall()]
                result_sets.append(rows)
            if not cur.nextset():
                break
        conn.commit()
        return result_sets
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def first_rows(sql, *params):
    for result in run_sql(sql, *params):
        return result
    return []


def db_error_message(exc):
    raw = str(exc)
    for phrase in BUSINESS_ERRORS:
        if phrase in raw:
            return phrase + "。"
    if "2601" in raw or "2627" in raw:
        return "该车牌号已经登记，请更换车牌号。"
    if "547" in raw:
        return "关联数据不符合要求，请检查所属学生信息。"
    app.logger.warning("Database error (details only on server): %s", raw)
    return "数据库操作失败，请检查数据库连接、输入内容或联系系统管理员。"


def _token_bytes(auth):
    return bytes.fromhex(auth["token_hex"])


def authenticate(username, password):
    results = run_sql(
        """
        SET NOCOUNT ON;
        DECLARE @token VARBINARY(32);
        EXEC dbo.usp_Login @UserName=?, @Password=?, @Token=@token OUTPUT;
        SELECT CONVERT(VARCHAR(64), @token, 2) AS TokenHex;
        """,
        username, password,
    )
    info = next(
        (rows[0] for rows in results if rows and "RoleName" in rows[0]), None
    )
    token_row = next(
        (rows[0] for rows in results if rows and "TokenHex" in rows[0]), None
    )
    if not info or not token_row or not token_row["TokenHex"]:
        raise ValueError("登录存储过程没有返回预期结果，请检查 SQL 脚本。")
    return {
        "username": str(info["UserName"]),
        "role": str(info["RoleName"]),
        "must_change": bool(info["MustChangePassword"]),
        "token_hex": str(token_row["TokenHex"]),
        "expires": time.time() + SESSION_SECONDS,
    }


def save_auth(auth):
    sid = secrets.token_urlsafe(32)
    with _sessions_lock:
        _sessions[sid] = auth
    # 清理之前的用户会话 cookie，但保留随机 CSRF 值
    csrf = session.get("csrf") or secrets.token_urlsafe(32)
    session.clear()
    session["sid"] = sid
    session["csrf"] = csrf


def clear_auth():
    sid = session.get("sid")
    if sid:
        with _sessions_lock:
            _sessions.pop(sid, None)
    session.clear()


def current_auth():
    if hasattr(g, "auth"):
        return g.auth
    sid = session.get("sid")
    with _sessions_lock:
        auth = _sessions.get(sid) if sid else None
        if auth and auth["expires"] <= time.time():
            _sessions.pop(sid, None)
            auth = None
    g.auth = auth
    return auth


def require_role(role=None):
    def decorator(view):
        @wraps(view)
        def wrapper(*args, **kwargs):
            auth = current_auth()
            if not auth:
                flash("请先登录。", "warning")
                return redirect(url_for("login"))
            if auth["must_change"] and request.endpoint not in ("change_password", "logout"):
                return redirect(url_for("change_password"))
            if role and auth["role"] != role:
                abort(403)
            return view(*args, **kwargs)
        return wrapper
    return decorator


def dashboard_for(auth):
    return "admin_dashboard" if auth["role"] == "ADMIN" else "student_dashboard"


@app.template_global()
def csrf_token():
    if "csrf" not in session:
        session["csrf"] = secrets.token_urlsafe(32)
    return session["csrf"]


@app.context_processor
def inject_auth():
    return {"auth": current_auth()}


@app.before_request
def verify_csrf():
    if request.method == "POST":
        expected = session.get("csrf", "")
        actual = request.form.get("csrf_token", "")
        if not expected or not actual or not hmac.compare_digest(expected, actual):
            abort(400, description="安全校验失败，请刷新页面后重试。")


@app.after_request
def security_headers(response):
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "same-origin"
    return response


@app.route("/")
def index():
    auth = current_auth()
    if not auth:
        return redirect(url_for("login"))
    if auth["must_change"]:
        return redirect(url_for("change_password"))
    return redirect(url_for(dashboard_for(auth)))


@app.route("/login", methods=["GET", "POST"])
def login():
    auth = current_auth()
    if auth and request.method == "GET":
        return redirect(url_for("index"))
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        if not username or not password:
            flash("请输入账号和密码。", "warning")
        else:
            try:
                new_auth = authenticate(username, password)
                if current_auth():
                    clear_auth()
                save_auth(new_auth)
                flash("登录成功，欢迎使用校园电动车管理平台！", "success")
                return redirect(url_for("index"))
            except (pyodbc.Error, ValueError) as exc:
                flash(db_error_message(exc) if isinstance(exc, pyodbc.Error) else str(exc), "error")
    return render_template("login.html", page_title="登录")


@app.route("/logout", methods=["POST"])
@require_role()
def logout():
    auth = current_auth()
    try:
        run_sql("EXEC dbo.usp_Logout @Token=?", _token_bytes(auth))
    except pyodbc.Error:
        app.logger.warning("DB logout failed; removing web session anyway")
    clear_auth()
    flash("你已退出登录。", "success")
    return redirect(url_for("login"))


@app.route("/change-password", methods=["GET", "POST"])
@require_role()
def change_password():
    auth = current_auth()
    if request.method == "POST":
        old_password = request.form.get("old_password", "")
        new_password = request.form.get("new_password", "")
        confirmation = request.form.get("confirm_password", "")
        if new_password != confirmation:
            flash("两次输入的新密码不一致。", "warning")
        elif len(new_password) < 8:
            flash("新密码至少需要8位。", "warning")
        else:
            try:
                run_sql(
                    "EXEC dbo.usp_ChangeMyPassword @Token=?, @OldPassword=?, @NewPassword=?",
                    _token_bytes(auth), old_password, new_password,
                )
                auth["must_change"] = False
                flash("密码修改成功。", "success")
                return redirect(url_for(dashboard_for(auth)))
            except pyodbc.Error as exc:
                flash(db_error_message(exc), "error")
    return render_template(
        "change_password.html",
        page_title="修改登录密码",
        must_change=auth["must_change"],
    )


@app.route("/student")
@require_role("STUDENT")
def student_dashboard():
    auth = current_auth()
    plate = request.args.get("plate", "").strip()
    try:
        rows = first_rows(
            "EXEC dbo.usp_StudentMyBikes @Token=?",
            _token_bytes(auth),
        )
        query_rows = []
        if plate:
            query_rows = first_rows(
                "EXEC dbo.usp_StudentFindByPlate @Token=?, @PlateNumber=?",
                _token_bytes(auth), plate,
            )
        return render_template(
            "student.html",
            page_title="学生工作台",
            bike_rows=rows,
            bike_count=sum(1 for row in rows if row["PlateNumber"] is not None),
            plate=plate,
            query_rows=query_rows,
        )
    except pyodbc.Error as exc:
        flash(db_error_message(exc), "error")
        return redirect(url_for("change_password")) if auth["must_change"] else render_template(
            "student.html", page_title="学生工作台", bike_rows=[],
            bike_count=0, plate=plate, query_rows=[],
        )


@app.route("/admin")
@require_role("ADMIN")
def admin_dashboard():
    auth = current_auth()
    filters = {
        "student_id": request.args.get("student_id", "").strip(),
        "owner_name": request.args.get("owner_name", "").strip(),
        "phone": request.args.get("phone", "").strip(),
        "counselor": request.args.get("counselor", "").strip(),
    }
    try:
        rows = first_rows(
            """EXEC dbo.usp_AdminGetOwnerInfo
               @Token=?, @StudentID=?, @OwnerName=?, @Phone=?, @Counselor=?""",
            _token_bytes(auth),
            filters["student_id"] or None,
            filters["owner_name"] or None,
            filters["phone"] or None,
            filters["counselor"] or None,
        )
        return render_template(
            "admin.html",
            page_title="车辆管理工作台",
            rows=rows,
            student_count=len({row["StudentID"] for row in rows}),
            bike_count=sum(1 for row in rows if row["PlateNumber"] is not None),
            filters=filters,
        )
    except pyodbc.Error as exc:
        flash(db_error_message(exc), "error")
        return render_template(
            "admin.html", page_title="车辆管理工作台",
            rows=[], student_count=0, bike_count=0, filters=filters,
        )


def _required(*names):
    """校验表单并取出字段（管理员身份由路由及数据库双重校验）。"""
    result = {name: request.form.get(name, "").strip() for name in names}
    if any(not value for value in result.values()):
        raise ValueError("请完整填写所有必填项目。")
    return result


def _bike_identity():
    return request.form.get("student_id", "").strip() or None


def _admin_action(sql, params, success):
    auth = current_auth()
    try:
        run_sql(sql, _token_bytes(auth), *params)
        flash(success, "success")
    except pyodbc.Error as exc:
        flash(db_error_message(exc), "error")
    return redirect(url_for("admin_dashboard") + "#manage")


@app.route("/admin/bike/add", methods=["POST"])
@require_role("ADMIN")
def add_bike():
    try:
        d = _required("owner_name", "phone", "counselor", "plate_number", "bike_model")
        return _admin_action(
            """EXEC dbo.usp_AdminAddBike
               @Token=?, @OwnerName=?, @Phone=?, @Counselor=?,
               @PlateNumber=?, @BikeModel=?, @StudentID=?""",
            [d["owner_name"], d["phone"], d["counselor"],
             d["plate_number"], d["bike_model"], _bike_identity()],
            "电动车登记成功。",
        )
    except ValueError as exc:
        flash(str(exc), "warning")
        return redirect(url_for("admin_dashboard") + "#manage")


@app.route("/admin/bike/update", methods=["POST"])
@require_role("ADMIN")
def update_bike():
    try:
        d = _required(
            "owner_name", "phone", "counselor", "old_plate",
            "new_plate", "new_model",
        )
        return _admin_action(
            """EXEC dbo.usp_AdminUpdateBike
               @Token=?, @OwnerName=?, @Phone=?, @Counselor=?,
               @OldPlateNumber=?, @NewPlateNumber=?, @NewBikeModel=?,
               @StudentID=?""",
            [d["owner_name"], d["phone"], d["counselor"],
             d["old_plate"], d["new_plate"], d["new_model"],
             _bike_identity()],
            "车辆牌号和型号修改成功。",
        )
    except ValueError as exc:
        flash(str(exc), "warning")
        return redirect(url_for("admin_dashboard") + "#manage")


@app.route("/admin/bike/delete", methods=["POST"])
@require_role("ADMIN")
def delete_bike():
    try:
        d = _required("owner_name", "phone", "counselor", "plate_number")
        return _admin_action(
            """EXEC dbo.usp_AdminDeleteBike
               @Token=?, @OwnerName=?, @Phone=?, @Counselor=?,
               @PlateNumber=?, @StudentID=?""",
            [d["owner_name"], d["phone"], d["counselor"],
             d["plate_number"], _bike_identity()],
            "车辆删除成功，学生信息未发生变化。",
        )
    except ValueError as exc:
        flash(str(exc), "warning")
        return redirect(url_for("admin_dashboard") + "#manage")


@app.route("/admin/password/reset", methods=["POST"])
@require_role("ADMIN")
def reset_password():
    try:
        d = _required("student_id", "new_password")
        return _admin_action(
            """EXEC dbo.usp_AdminResetStudentPassword
               @Token=?, @TargetStudentID=?, @NewPassword=?""",
            [d["student_id"], d["new_password"]],
            "学生密码重置成功，该学生下次登录需要修改密码。",
        )
    except ValueError as exc:
        flash(str(exc), "warning")
        return redirect(url_for("admin_dashboard") + "#reset-password")


@app.errorhandler(400)
def bad_request(error):
    return render_template("error.html", page_title="请求无效",
                           title="请求校验失败", message=error.description), 400


@app.errorhandler(403)
def forbidden(error):
    return render_template("error.html", page_title="没有权限",
                           title="暂无访问权限", message="你的账号无权进入此页面。"), 403


@app.errorhandler(404)
def not_found(error):
    return render_template("error.html", page_title="页面不存在",
                           title="页面不存在", message="请从导航栏重新进入。"), 404


if __name__ == "__main__":
    print("校园电动车管理平台：http://127.0.0.1:5000")
    app.run(host="127.0.0.1", port=int(os.getenv("PORT", "5000")),
            debug=False, threaded=True)
