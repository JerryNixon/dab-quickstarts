-- Schema and seed data for Azure SQL deployment (used by post-provision.ps1)
-- Local development uses the SQL Database Project in /database instead.

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Todos')
CREATE TABLE [dbo].[Todos] (
    [TodoId]    INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    [Title]     NVARCHAR(200) NOT NULL,
    [DueDate]   DATE NOT NULL,
    [Owner]     NVARCHAR(128) NOT NULL DEFAULT 'anonymous',
    [Completed] BIT NOT NULL DEFAULT 0
);
GO

IF NOT EXISTS (SELECT TOP 1 1 FROM [dbo].[Todos])
INSERT INTO [dbo].[Todos] ([Title], [DueDate], [Owner], [Completed])
VALUES
    (N'Learn Data API Builder', DATEADD(DAY, 7, GETDATE()), 'anonymous', 0),
    (N'Deploy to Azure', DATEADD(DAY, 14, GETDATE()), 'anonymous', 0),
    (N'Build something awesome', DATEADD(DAY, 30, GETDATE()), 'anonymous', 0);
GO
