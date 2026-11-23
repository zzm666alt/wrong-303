/*
校园电动车管理平台（SQL Server 2016 SP1+ / SSMS）
仅首次初始化运行一次；需要数据库创建与对象创建权限。
业务表：Student、ElectricBike
权限辅助表：AppAccount、LoginSession
安全说明：此版本用于课程项目；生产环境应在应用层用 Argon2id/bcrypt
替换下方演示用“随机盐 + SHA2_256”，并启用 TLS、限流和操作审计。
*/

-- 01. 建立数据库
IF DB_ID(N'CampusEVPlatformDB') IS NULL
    EXEC(N'CREATE DATABASE CampusEVPlatformDB');
GO
USE CampusEVPlatformDB;
GO

-- 02. 学生信息表：电动车管理员没有更新本表的存储过程
CREATE TABLE dbo.Student
(
    StudentID   VARCHAR(20)  NOT NULL PRIMARY KEY, -- 学号/登录账号
    FullName    NVARCHAR(50) NOT NULL,             -- 姓名
    ClassName   NVARCHAR(50) NOT NULL,             -- 班级
    Department  NVARCHAR(80) NOT NULL,             -- 系别
    Counselor   NVARCHAR(50) NOT NULL,             -- 辅导员
    Phone       VARCHAR(20)  NOT NULL              -- 学生联系电话
);
GO

-- 03. 电动车信息表：允许一人拥有多辆车；无车则无需插入行
CREATE TABLE dbo.ElectricBike
(
    BikeID      INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    PlateNumber NVARCHAR(30)      NOT NULL UNIQUE, -- 牌号
    BikeModel   NVARCHAR(100)     NOT NULL,        -- 型号
    StudentID   VARCHAR(20)       NOT NULL,
    CONSTRAINT FK_ElectricBike_Student
        FOREIGN KEY (StudentID) REFERENCES dbo.Student(StudentID)
);
GO
CREATE INDEX IX_ElectricBike_StudentID ON dbo.ElectricBike(StudentID);
GO

-- 04. 账号表：学生账号等于学号；管理员账号独立
CREATE TABLE dbo.AppAccount
(
    AccountID           INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    UserName            VARCHAR(32)  NOT NULL UNIQUE,
    StudentID           VARCHAR(20)  NULL,
    RoleName            VARCHAR(10)  NOT NULL,
    PasswordSalt        BINARY(16)    NOT NULL,
    PasswordHash        BINARY(32)    NOT NULL,
    MustChangePassword  BIT           NOT NULL DEFAULT (1),
    IsActive            BIT           NOT NULL DEFAULT (1),
    CONSTRAINT FK_AppAccount_Student
        FOREIGN KEY (StudentID) REFERENCES dbo.Student(StudentID),
    CONSTRAINT CK_AppAccount_Identity CHECK
    (
       (RoleName = 'STUDENT' AND StudentID IS NOT NULL AND UserName = StudentID)
       OR
       (RoleName = 'ADMIN' AND StudentID IS NULL)
    )
);
GO
CREATE UNIQUE INDEX UX_AppAccount_StudentID
    ON dbo.AppAccount(StudentID) WHERE StudentID IS NOT NULL;
GO

-- 05. 会话表：只存随机令牌的摘要，不明文存放令牌
CREATE TABLE dbo.LoginSession
(
    TokenHash  BINARY(32)   NOT NULL PRIMARY KEY,
    AccountID  INT          NOT NULL,
    ExpiresAt  DATETIME2(0) NOT NULL,
    CONSTRAINT FK_LoginSession_Account
        FOREIGN KEY (AccountID) REFERENCES dbo.AppAccount(AccountID)
);
GO
CREATE INDEX IX_LoginSession_AccountID ON dbo.LoginSession(AccountID);
GO

-- 06. 录入学生时，自动建立“学号 / 初始密码 123456”账号
CREATE OR ALTER TRIGGER dbo.trg_Student_CreateAccount
ON dbo.Student
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @NewAccounts TABLE
    (
        StudentID VARCHAR(20) PRIMARY KEY,
        Salt      BINARY(16) NOT NULL
    );

    INSERT INTO @NewAccounts(StudentID, Salt)
    SELECT StudentID, CRYPT_GEN_RANDOM(16)
    FROM inserted;

    INSERT INTO dbo.AppAccount
        (UserName, StudentID, RoleName, PasswordSalt,
         PasswordHash, MustChangePassword)
    SELECT
        N.StudentID,
        N.StudentID,
        'STUDENT',
        N.Salt,
        CONVERT(BINARY(32), HASHBYTES('SHA2_256',
            N.Salt + CONVERT(VARBINARY(400), N'123456'))),
        1
    FROM @NewAccounts AS N;
END;
GO

-- 07. 电动车展示视图：学生无车时，车牌、型号显示 NULL
-- 姓名、电话、辅导员统一从 Student 获取
CREATE OR ALTER VIEW dbo.v_StudentBikeInfo
AS
SELECT
    S.StudentID,
    S.FullName    AS OwnerName,
    S.Phone       AS ContactPhone,
    S.Counselor,
    B.PlateNumber,
    B.BikeModel
FROM dbo.Student AS S
LEFT JOIN dbo.ElectricBike AS B
       ON B.StudentID = S.StudentID;
GO

-- 08. 内部鉴权函数：由随机登录令牌找到本人及角色
CREATE OR ALTER FUNCTION dbo.fn_AuthSession(@Token VARBINARY(32))
RETURNS TABLE
AS
RETURN
(
    SELECT
        A.AccountID,
        A.UserName,
        A.StudentID,
        A.RoleName,
        A.MustChangePassword
    FROM dbo.LoginSession AS LS
    JOIN dbo.AppAccount AS A ON A.AccountID = LS.AccountID
    WHERE LS.TokenHash = CONVERT(BINARY(32), HASHBYTES('SHA2_256', @Token))
      AND LS.ExpiresAt > SYSUTCDATETIME()
      AND A.IsActive = 1
);
GO

-- 09. 登录：学生学号 / 管理员账号；返回 32 字节会话令牌
CREATE OR ALTER PROCEDURE dbo.usp_Login
    @UserName VARCHAR(32),
    @Password NVARCHAR(200),
    @Token VARBINARY(32) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Token = NULL;

    DECLARE @AccountID INT, @Salt BINARY(16),
            @StoredHash BINARY(32), @IsActive BIT,
            @RoleName VARCHAR(10), @MustChange BIT;

    SELECT
        @AccountID = AccountID,
        @Salt = PasswordSalt,
        @StoredHash = PasswordHash,
        @IsActive = IsActive,
        @RoleName = RoleName,
        @MustChange = MustChangePassword
    FROM dbo.AppAccount
    WHERE UserName = @UserName;

    IF @AccountID IS NULL
       OR @Password IS NULL
       OR @IsActive <> 1
       OR @StoredHash <> CONVERT(BINARY(32), HASHBYTES('SHA2_256',
              @Salt + CONVERT(VARBINARY(400), @Password)))
        THROW 51001, N'账号或密码错误，或账号已停用。', 1;

    SET @Token = CRYPT_GEN_RANDOM(32);

    INSERT INTO dbo.LoginSession(TokenHash, AccountID, ExpiresAt)
    VALUES
    (
        CONVERT(BINARY(32), HASHBYTES('SHA2_256', @Token)),
        @AccountID,
        DATEADD(HOUR, 2, SYSUTCDATETIME())
    );

    SELECT @UserName AS UserName, @RoleName AS RoleName,
           @MustChange AS MustChangePassword,
           DATEADD(HOUR, 2, SYSUTCDATETIME()) AS ExpiresAtUTC;
END;
GO

-- 10. 学生或管理员修改自己的密码（需原密码）
CREATE OR ALTER PROCEDURE dbo.usp_ChangeMyPassword
    @Token VARBINARY(32),
    @OldPassword NVARCHAR(200),
    @NewPassword NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @AccountID INT, @OldSalt BINARY(16),
            @StoredHash BINARY(32), @NewSalt BINARY(16);

    SELECT
        @AccountID = A.AccountID,
        @OldSalt = A.PasswordSalt,
        @StoredHash = A.PasswordHash
    FROM dbo.fn_AuthSession(@Token) AS Auth
    JOIN dbo.AppAccount AS A ON A.AccountID = Auth.AccountID;

    IF @AccountID IS NULL
        THROW 51002, N'尚未登录或登录已过期。', 1;
    IF @OldPassword IS NULL
       OR @StoredHash <> CONVERT(BINARY(32), HASHBYTES('SHA2_256',
              @OldSalt + CONVERT(VARBINARY(400), @OldPassword)))
        THROW 51003, N'原密码不正确。', 1;
    IF @NewPassword IS NULL OR LEN(@NewPassword) < 8
       OR @NewPassword = N'123456'
       OR @NewPassword = @OldPassword
        THROW 51004, N'新密码至少8位，且不能与原密码相同或使用初始密码。', 1;

    SET @NewSalt = CRYPT_GEN_RANDOM(16);
    UPDATE dbo.AppAccount
    SET PasswordSalt = @NewSalt,
        PasswordHash = CONVERT(BINARY(32), HASHBYTES('SHA2_256',
            @NewSalt + CONVERT(VARBINARY(400), @NewPassword))),
        MustChangePassword = 0
    WHERE AccountID = @AccountID;

    -- 修改密码后踢出其他会话，保留当前会话
    DELETE FROM dbo.LoginSession
    WHERE AccountID = @AccountID
      AND TokenHash <> CONVERT(BINARY(32), HASHBYTES('SHA2_256', @Token));

    SELECT N'密码修改成功' AS Message;
END;
GO

-- 11. 学生查询自己的车辆（无车也返回一行，牌号/型号为 NULL）
CREATE OR ALTER PROCEDURE dbo.usp_StudentMyBikes
    @Token VARBINARY(32)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @StudentID VARCHAR(20);

    SELECT @StudentID = StudentID
    FROM dbo.fn_AuthSession(@Token)
    WHERE RoleName = 'STUDENT' AND MustChangePassword = 0;

    IF @StudentID IS NULL
        THROW 51005, N'学生未登录，或需要先修改初始密码。', 1;

    SELECT StudentID, PlateNumber, BikeModel,
           OwnerName, ContactPhone, Counselor
    FROM dbo.v_StudentBikeInfo
    WHERE StudentID = @StudentID
    ORDER BY PlateNumber;
END;
GO

-- 12. 学生根据车牌查询车主姓名、联系电话、辅导员
CREATE OR ALTER PROCEDURE dbo.usp_StudentFindByPlate
    @Token VARBINARY(32),
    @PlateNumber NVARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.fn_AuthSession(@Token)
        WHERE RoleName = 'STUDENT' AND MustChangePassword = 0
    )
        THROW 51006, N'学生未登录，或需要先修改初始密码。', 1;

    SELECT S.FullName AS OwnerName,
           S.Phone AS ContactPhone,
           S.Counselor
    FROM dbo.ElectricBike AS B
    JOIN dbo.Student AS S ON S.StudentID = B.StudentID
    WHERE B.PlateNumber = @PlateNumber;
END;
GO

-- 13. 管理员重置任意学生的密码（默认重置为 123456）
CREATE OR ALTER PROCEDURE dbo.usp_AdminResetStudentPassword
    @Token VARBINARY(32),
    @TargetStudentID VARCHAR(20),
    @NewPassword NVARCHAR(200) = N'123456'
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.fn_AuthSession(@Token)
        WHERE RoleName = 'ADMIN' AND MustChangePassword = 0
    )
        THROW 51007, N'无管理员权限，或需要先修改初始密码。', 1;

    IF @NewPassword IS NULL OR LEN(@NewPassword) < 6
        THROW 51008, N'重置密码至少为6位。', 1;

    DECLARE @AccountID INT, @Salt BINARY(16) = CRYPT_GEN_RANDOM(16);
    SELECT @AccountID = AccountID
    FROM dbo.AppAccount
    WHERE StudentID = @TargetStudentID AND RoleName = 'STUDENT';

    IF @AccountID IS NULL
        THROW 51009, N'不存在该学生账号。', 1;

    UPDATE dbo.AppAccount
    SET PasswordSalt = @Salt,
        PasswordHash = CONVERT(BINARY(32), HASHBYTES('SHA2_256',
            @Salt + CONVERT(VARBINARY(400), @NewPassword))),
        MustChangePassword = 1
    WHERE AccountID = @AccountID;

    -- 重置后让学生原有会话失效
    DELETE FROM dbo.LoginSession WHERE AccountID = @AccountID;
    SELECT N'学生密码已重置，下次登录必须修改密码' AS Message;
END;
GO

-- 14. 管理员增加车辆：通过姓名+电话+辅导员定位学生
-- 可选学号用于同名、同电话等情况下的精准定位
CREATE OR ALTER PROCEDURE dbo.usp_AdminAddBike
    @Token VARBINARY(32),
    @OwnerName NVARCHAR(50),
    @Phone VARCHAR(20),
    @Counselor NVARCHAR(50),
    @PlateNumber NVARCHAR(30),
    @BikeModel NVARCHAR(100),
    @StudentID VARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.fn_AuthSession(@Token)
        WHERE RoleName = 'ADMIN' AND MustChangePassword = 0
    )
        THROW 51010, N'没有管理员操作权限。', 1;

    IF NULLIF(LTRIM(RTRIM(@PlateNumber)), N'') IS NULL
       OR NULLIF(LTRIM(RTRIM(@BikeModel)), N'') IS NULL
        THROW 51011, N'牌号和型号不能为空。', 1;

    DECLARE @FoundID VARCHAR(20), @Matches INT;
    SELECT @Matches = COUNT(*), @FoundID = MAX(StudentID)
    FROM dbo.Student
    WHERE FullName = @OwnerName AND Phone = @Phone
      AND Counselor = @Counselor
      AND (@StudentID IS NULL OR StudentID = @StudentID);

    IF @Matches <> 1
        THROW 51012, N'无法唯一定位学生，请核对姓名、电话、辅导员，必要时提供学号。', 1;

    INSERT INTO dbo.ElectricBike(PlateNumber, BikeModel, StudentID)
    VALUES (@PlateNumber, @BikeModel, @FoundID);

    SELECT N'车辆添加成功' AS Message, @FoundID AS StudentID;
END;
GO

-- 15. 管理员修改指定车牌的车辆信息（仅修改车辆，不修改学生表）
CREATE OR ALTER PROCEDURE dbo.usp_AdminUpdateBike
    @Token VARBINARY(32),
    @OwnerName NVARCHAR(50),
    @Phone VARCHAR(20),
    @Counselor NVARCHAR(50),
    @OldPlateNumber NVARCHAR(30),
    @NewPlateNumber NVARCHAR(30),
    @NewBikeModel NVARCHAR(100),
    @StudentID VARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.fn_AuthSession(@Token)
        WHERE RoleName = 'ADMIN' AND MustChangePassword = 0
    )
        THROW 51013, N'没有管理员操作权限。', 1;

    IF NULLIF(LTRIM(RTRIM(@NewPlateNumber)), N'') IS NULL
       OR NULLIF(LTRIM(RTRIM(@NewBikeModel)), N'') IS NULL
        THROW 51014, N'新牌号和新型号不能为空。', 1;

    DECLARE @FoundID VARCHAR(20), @Matches INT;
    SELECT @Matches = COUNT(*), @FoundID = MAX(StudentID)
    FROM dbo.Student
    WHERE FullName = @OwnerName AND Phone = @Phone
      AND Counselor = @Counselor
      AND (@StudentID IS NULL OR StudentID = @StudentID);

    IF @Matches <> 1
        THROW 51015, N'无法唯一定位学生，请核对身份信息。', 1;

    UPDATE dbo.ElectricBike
    SET PlateNumber = @NewPlateNumber, BikeModel = @NewBikeModel
    WHERE StudentID = @FoundID AND PlateNumber = @OldPlateNumber;

    IF @@ROWCOUNT = 0
        THROW 51016, N'未找到该学生名下的原车牌。', 1;

    SELECT N'车辆信息修改成功' AS Message;
END;
GO

-- 16. 管理员删除车辆（只删除车辆记录，不删除学生资料）
CREATE OR ALTER PROCEDURE dbo.usp_AdminDeleteBike
    @Token VARBINARY(32),
    @OwnerName NVARCHAR(50),
    @Phone VARCHAR(20),
    @Counselor NVARCHAR(50),
    @PlateNumber NVARCHAR(30),
    @StudentID VARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.fn_AuthSession(@Token)
        WHERE RoleName = 'ADMIN' AND MustChangePassword = 0
    )
        THROW 51017, N'没有管理员操作权限。', 1;

    DECLARE @FoundID VARCHAR(20), @Matches INT;
    SELECT @Matches = COUNT(*), @FoundID = MAX(StudentID)
    FROM dbo.Student
    WHERE FullName = @OwnerName AND Phone = @Phone
      AND Counselor = @Counselor
      AND (@StudentID IS NULL OR StudentID = @StudentID);

    IF @Matches <> 1
        THROW 51018, N'无法唯一定位学生，请核对身份信息。', 1;

    DELETE FROM dbo.ElectricBike
    WHERE StudentID = @FoundID AND PlateNumber = @PlateNumber;

    IF @@ROWCOUNT = 0
        THROW 51019, N'未找到该学生名下的指定车辆。', 1;

    SELECT N'车辆删除成功；学生资料保持不变' AS Message;
END;
GO

-- 17. 管理员查询全部车主信息（含学生表字段）
-- 可按学号、姓名、电话、辅导员筛选；未填写筛选项时返回所有学生
CREATE OR ALTER PROCEDURE dbo.usp_AdminGetOwnerInfo
    @Token VARBINARY(32),
    @StudentID VARCHAR(20) = NULL,
    @OwnerName NVARCHAR(50) = NULL,
    @Phone VARCHAR(20) = NULL,
    @Counselor NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.fn_AuthSession(@Token)
        WHERE RoleName = 'ADMIN' AND MustChangePassword = 0
    )
        THROW 51020, N'没有管理员查询权限。', 1;

    SELECT S.StudentID, S.FullName, S.ClassName,
           S.Department, S.Counselor, S.Phone,
           B.PlateNumber, B.BikeModel
    FROM dbo.Student AS S
    LEFT JOIN dbo.ElectricBike AS B ON B.StudentID = S.StudentID
    WHERE (@StudentID IS NULL OR S.StudentID = @StudentID)
      AND (@OwnerName IS NULL OR S.FullName = @OwnerName)
      AND (@Phone IS NULL OR S.Phone = @Phone)
      AND (@Counselor IS NULL OR S.Counselor = @Counselor)
    ORDER BY S.StudentID, B.PlateNumber;
END;
GO

-- 18. 退出登录
CREATE OR ALTER PROCEDURE dbo.usp_Logout
    @Token VARBINARY(32)
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.LoginSession
    WHERE TokenHash = CONVERT(BINARY(32), HASHBYTES('SHA2_256', @Token));
    SELECT N'退出成功' AS Message;
END;
GO

-- 19. 应用运行角色：只授予执行存储过程的权限，不授予表更新权限
-- 真实系统须由 DBA 将服务端专用 SQL 用户加入该角色；
-- 学生和业务管理员账号通过 usp_Login 鉴权，不是 SQL Server 登录名。
CREATE ROLE CampusEV_AppRole;
GO
GRANT EXECUTE ON dbo.usp_Login TO CampusEV_AppRole;
GRANT EXECUTE ON dbo.usp_Logout TO CampusEV_AppRole;
GRANT EXECUTE ON dbo.usp_ChangeMyPassword TO CampusEV_AppRole;
GRANT EXECUTE ON dbo.usp_StudentMyBikes TO CampusEV_AppRole;
GRANT EXECUTE ON dbo.usp_StudentFindByPlate TO CampusEV_AppRole;
GRANT EXECUTE ON dbo.usp_AdminResetStudentPassword TO CampusEV_AppRole;
GRANT EXECUTE ON dbo.usp_AdminAddBike TO CampusEV_AppRole;
GRANT EXECUTE ON dbo.usp_AdminUpdateBike TO CampusEV_AppRole;
GRANT EXECUTE ON dbo.usp_AdminDeleteBike TO CampusEV_AppRole;
GRANT EXECUTE ON dbo.usp_AdminGetOwnerInfo TO CampusEV_AppRole;
-- 再明确禁止应用角色直接写学生表（存储过程按授权执行）
DENY INSERT, UPDATE, DELETE ON dbo.Student TO CampusEV_AppRole;
GO

-- 20. 模拟学校学籍系统录入学生：触发器自动为每人建账号
INSERT INTO dbo.Student
    (StudentID, FullName, ClassName, Department, Counselor, Phone)
VALUES
    ('20260001', N'张三', N'软件工程1班', N'计算机系', N'李老师', '13800000001'),
    ('20260002', N'李四', N'软件工程2班', N'计算机系', N'李老师', '13800000002'),
    ('20260003', N'王五', N'电子信息1班', N'电子工程系', N'王老师', '13800000003'),
    ('20260004', N'赵六', N'自动化1班', N'机电工程系', N'陈老师', '13800000004');
GO

-- 21. 录入两辆演示电动车：李四、赵六无车辆
INSERT INTO dbo.ElectricBike(PlateNumber, BikeModel, StudentID)
VALUES
    (N'校A001', N'雅迪冠能', '20260001'),
    (N'校A003', N'小牛UQi',  '20260003');
GO

-- 22. 创建电动车管理员业务账号
-- 初始用户名：bikeadmin；初始密码：Admin@Init2026!
-- 首次登录必须修改密码
DECLARE @AdminSalt BINARY(16) = CRYPT_GEN_RANDOM(16);
INSERT INTO dbo.AppAccount
    (UserName, StudentID, RoleName, PasswordSalt,
     PasswordHash, MustChangePassword)
VALUES
    ('bikeadmin', NULL, 'ADMIN', @AdminSalt,
     CONVERT(BINARY(32), HASHBYTES('SHA2_256',
         @AdminSalt + CONVERT(VARBINARY(400), N'Admin@Init2026!'))),
     1);
GO

-- 23. 初始化结果检查（DBA/开发者运行；不代表学生能直接查询该视图）
SELECT * FROM dbo.v_StudentBikeInfo ORDER BY StudentID;
GO

/*
================= 学生操作示例（单独执行）=================
DECLARE @StudentToken VARBINARY(32);
EXEC dbo.usp_Login
    @UserName='20260002', @Password=N'123456',
    @Token=@StudentToken OUTPUT;

-- 首次登录先修改自己的密码
EXEC dbo.usp_ChangeMyPassword
    @Token=@StudentToken,
    @OldPassword=N'123456',
    @NewPassword=N'Student@2026!';

-- 查询自己的车：李四无车辆，返回 NULL、NULL
EXEC dbo.usp_StudentMyBikes @Token=@StudentToken;

-- 通过车牌查其他车主姓名、电话、辅导员
EXEC dbo.usp_StudentFindByPlate
    @Token=@StudentToken, @PlateNumber=N'校A001';

EXEC dbo.usp_Logout @Token=@StudentToken;
GO

================ 管理员操作示例（单独执行）================
DECLARE @AdminToken VARBINARY(32);
EXEC dbo.usp_Login
    @UserName='bikeadmin', @Password=N'Admin@Init2026!',
    @Token=@AdminToken OUTPUT;

-- 管理员首次登录修改自己的密码
EXEC dbo.usp_ChangeMyPassword
    @Token=@AdminToken,
    @OldPassword=N'Admin@Init2026!',
    @NewPassword=N'Manager@2026!';

-- 添加李四的电动车
EXEC dbo.usp_AdminAddBike
    @Token=@AdminToken,
    @OwnerName=N'李四',
    @Phone='13800000002',
    @Counselor=N'李老师',
    @PlateNumber=N'校A002',
    @BikeModel=N'爱玛小熊';

-- 修改李四的车牌、型号
EXEC dbo.usp_AdminUpdateBike
    @Token=@AdminToken,
    @OwnerName=N'李四',
    @Phone='13800000002',
    @Counselor=N'李老师',
    @OldPlateNumber=N'校A002',
    @NewPlateNumber=N'校A022',
    @NewBikeModel=N'爱玛新款';

-- 查询李四的全部学生信息和车辆信息
EXEC dbo.usp_AdminGetOwnerInfo
    @Token=@AdminToken, @StudentID='20260002';

-- 查询所有学生及对应车辆
EXEC dbo.usp_AdminGetOwnerInfo @Token=@AdminToken;

-- 将张三的密码重置为123456，强制下次修改
EXEC dbo.usp_AdminResetStudentPassword
    @Token=@AdminToken, @TargetStudentID='20260001';

-- 删除李四的车辆，不删除学生记录
EXEC dbo.usp_AdminDeleteBike
    @Token=@AdminToken,
    @OwnerName=N'李四',
    @Phone='13800000002',
    @Counselor=N'李老师',
    @PlateNumber=N'校A022';

EXEC dbo.usp_Logout @Token=@AdminToken;
GO
*/
