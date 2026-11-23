/*
运行时机：
1. 先运行【校园电动车管理平台_SQL_Server.sql】创建数据库/角色/存储过程
2. 修改下面的 @WebPassword 为自己生成的强密码后，在 SSMS 执行本文件
3. 将相同密码写入网页项目 .env 的 SQL_PASSWORD

此账号只加入 CampusEV_AppRole，仅可执行获授权的存储过程；
不要用 sa 或其他 dbo/管理员身份连接网页应用。
*/
USE master;
GO

DECLARE @WebPassword NVARCHAR(128) = N'';
IF LEN(@WebPassword) < 16
BEGIN
    THROW 52000, N'请先将 @WebPassword 设置为长度至少 16 位的随机强密码，再运行脚本。', 1;
END;

IF SUSER_ID(N'campus_ev_web') IS NULL
BEGIN
    DECLARE @Statement NVARCHAR(MAX);
    SET @Statement = N'CREATE LOGIN [campus_ev_web] WITH PASSWORD = N'
                   + QUOTENAME(@WebPassword, '''')
                   + N', CHECK_POLICY = ON;';
    EXEC(@Statement);
END
ELSE
BEGIN
    PRINT N'服务器登录 campus_ev_web 已存在。若需更改密码请使用 ALTER LOGIN。';
END;
GO

USE CampusEVPlatformDB;
GO
IF DATABASE_PRINCIPAL_ID(N'campus_ev_web') IS NULL
    CREATE USER [campus_ev_web] FOR LOGIN [campus_ev_web];
GO

IF DATABASE_PRINCIPAL_ID(N'CampusEV_AppRole') IS NULL
    THROW 52001, N'缺少 CampusEV_AppRole：请先运行初始化 SQL 文件。', 1;

ALTER ROLE CampusEV_AppRole ADD MEMBER [campus_ev_web];
GO

-- 验证：网页账号只需要存储过程 EXECUTE 权限
SELECT dp.name AS DatabaseUser, dr.name AS DatabaseRole
FROM sys.database_role_members rm
JOIN sys.database_principals dr ON rm.role_principal_id = dr.principal_id
JOIN sys.database_principals dp ON rm.member_principal_id = dp.principal_id
WHERE dp.name = N'campus_ev_web';
GO
