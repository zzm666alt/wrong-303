# 校园电动车管理平台 · 简易网页（SQL Server + Flask）

这是可连接前一版 SQL Server 数据库的**完整入门级 Web 界面**，分为学生端和管理员端。

## 一、支持的功能

| 学生账号 | 管理员账号 |
| --- | --- |
| 使用学号及密码登录 | 使用管理员账号登录 |
| 首次登录强制修改初始密码 | 首次登录强制修改管理员密码 |
| 自助修改本人密码 | 修改自己的密码 |
| 查询本人车辆（无车显示“未登记”） | 按学号、姓名、电话、辅导员筛选全部学生资料 |
| 输入车牌号查询车主姓名、电话和辅导员 | 添加、修改、删除电动车，重置任意学生密码 |
| 不可修改学生档案 | **不能修改学生电话等学生档案数据** |

业务数据仍然保存在 **Student 和 ElectricBike 两张表**。安全辅助表 `AppAccount`、`LoginSession` 来自此前数据库脚本。

**先看界面**：如果尚未配置 SQL Server，可以直接用浏览器打开 `preview/预览_登录页.html`、`preview/预览_学生端.html`、`preview/预览_管理员端.html`。这三个是可离线查看的**静态示例**，不执行真实数据库操作。

## 二、运行步骤（推荐 Windows + SSMS）

### 1. 初始化 SQL Server 数据库

如果以前没有执行过初始化代码，请在 SSMS 中以有权限的账号运行随项目打包的：

`校园电动车管理平台_SQL_Server.sql`

此脚本**只适合首次初始化运行一次**；再次运行会因对象/测试数据已存在而报错，**不要为了清除报错而直接删库**。

如果上一轮已经运行成功，可跳过此步骤。

### 2. 为网页创建最低权限数据库登录账号

使用 SSMS 打开 `setup_web_login.sql`，找到：

```sql
DECLARE @WebPassword NVARCHAR(128) = N'';
```

将空字符串改成**你自己生成的、至少16位的强密码**，然后执行。

这一步会创建 SQL Server 登录 `campus_ev_web`，并加入 `CampusEV_AppRole`，使网页只能执行允许的存储过程，不能直接编辑学生信息表。

> 注意：**不要让网页连接 `sa` 或 `dbo` 高权限数据库账号。** 如果使用 Windows 身份验证，也应给运行网页的 Windows 账号创建独立的、受限的 SQL Server 用户。

### 3. 安装 Python 与 ODBC 驱动

- Python **3.10 或更高版本**
- SQL Server 2016 SP1 或更高版本（支持 `CREATE OR ALTER`）
- Microsoft **ODBC Driver 18 for SQL Server**
- SQL Server Management Studio（SSMS）用于管理数据库

如果电脑上只有 ODBC Driver 17，则将 `.env` 中的驱动名称改为 `ODBC Driver 17 for SQL Server`。

### 4. 配置数据库连接

把 `.env.example` 复制为 `.env`，修改：

```dotenv
SQL_SERVER=localhost
SQL_DATABASE=CampusEVPlatformDB
SQL_DRIVER=ODBC Driver 18 for SQL Server
SQL_AUTH_MODE=sql
SQL_USERNAME=campus_ev_web
SQL_PASSWORD=上一步自己设置的密码
SQL_ENCRYPT=yes
SQL_TRUST_SERVER_CERTIFICATE=yes
```

如果使用的是 SQL Server Express，`SQL_SERVER` 通常可设置为 `localhost\SQLEXPRESS`。

`FLASK_SECRET_KEY` 建议填写随机长字符串（可使用 `python -c "import secrets; print(secrets.token_hex(32))"` 生成）。

此处信任服务器证书仅用于本机演示。正式部署应配置有效 TLS 证书，将 `SQL_TRUST_SERVER_CERTIFICATE=no`。

### 5. 安装依赖并启动网页

在此项目文件夹打开终端，执行：

```bash
python -m pip install -r requirements.txt
python app.py
```

浏览器打开：

**http://127.0.0.1:5000**

如果你安装了多个 Python 版本，在 Windows 也可使用 `py -m pip ...`、`py app.py`。

### 6. 登录示例账号

- 学生：`20260001`，初始密码：`123456`
- 管理员：`bikeadmin`，初始密码：`Admin@Init2026!`

**两者首次登录都必须修改初始密码。**

示例车辆为：
- `校A001` → 张三，雅迪冠能
- `校A003` → 王五，小牛UQi
- `20260002`（李四）、`20260004`（赵六）初始无车

## 三、文件结构

```text
校园电动车管理平台_网页项目/
├─ app.py                             # Flask 后端接口：所有业务经 SQL 存储过程
├─ templates/
│  ├─ base.html                       # 统一布局
│  ├─ login.html                      # 登录界面
│  ├─ change_password.html            # 修改密码界面
│  ├─ student.html                    # 学生工作台
│  ├─ admin.html                      # 管理员工作台
│  └─ error.html                      # 错误页面
├─ static/
│  ├─ style.css                       # 中文响应式界面样式
│  └─ app.js                          # 密码显隐和表格编辑回填
├─ preview/                           # 无需数据库的3个静态界面预览
├─ .env.example                       # 数据库连接配置模板
├─ requirements.txt
├─ setup_web_login.sql                # 创建最低权限 SQL 登录
├─ 校园电动车管理平台_SQL_Server.sql       # 上一版 SQL 初始化文件
└─ README.md
```

## 四、设计注意事项

- **管理员无法通过网页修改学生表**：后端没有相关接口，并且数据库应用角色只允许执行规定的存储过程。
- 车主姓名、电话、辅导员始终从学生表按学号关联得到，不在车辆表复制这三项数据。
- 无车学生无需插入空车辆记录；使用 LEFT JOIN 查询时会显示车牌和型号 `NULL`。
- 同名学生可能出现，添加/修改/删除车辆时建议同时填写学号以唯一定位。
- 本项目用参数化语句调用存储过程，并提供 CSRF 校验、服务端会话、最小权限 SQL 用户。
- **密码**：数据库初始化脚本采用随机盐 + SHA-256，是教学演示实现，不应作为生产系统的最终密码方案。正式部署应迁移到 Argon2id/bcrypt。
- **会话**：网页服务端会话暂存在 Python 内存，适合单进程本机演示；程序重启后须重新登录。正式部署可使用 Redis 等共享服务端会话。
- **隐私**：车牌查询会显示学生个人联系方式；实际校园部署应依照校内授权、数据最小化原则补充限流、访问日志和隐私告知。
- **正式上线**：还需 HTTPS、登录限流/防爆破、审计、自动备份、异常监控，以及更严格的数据授权审核。

## 五、常见问题

**Q：出现“数据库操作失败”怎么办？**

请检查 SQL Server 服务是否启动、服务器地址、数据库名、账号密码、ODBC 驱动，以及 `setup_web_login.sql` 是否执行成功。网页不会显示底层数据库错误细节，具体原因记录在服务端终端。

**Q：能不能不填写学号来添加车辆？**

可以。填写姓名、电话、辅导员即可；如果无法唯一对应一个学生，则要求补充学号。

**Q：管理员为何不能修改电话？**

电话由 Student 表维护。管理员只可读学生资料，不能通过平台直接改写。学生档案应由学籍数据维护人员在独立权限下更新。

**Q：是否已经实现安装即用的公网网站？**

不是。本项目是功能完整的*本机课程演示版网页*，仍需要 SQL Server 数据库、驱动、运行环境和 `.env` 配置。**没有实际 SQL Server 时，页面无法完成登录与查询。**
