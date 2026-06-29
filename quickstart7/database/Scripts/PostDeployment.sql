IF NOT EXISTS (SELECT 1 FROM [dbo].[Todos])
BEGIN
    INSERT INTO [dbo].[Todos] ([Title], [DueDate], [Owner], [Completed])
    VALUES
        (N'Learn Data API Builder', DATEADD(DAY, 7, GETDATE()), 'anonymous', 0),
        (N'Run DAB as a process sidecar', DATEADD(DAY, 14, GETDATE()), 'anonymous', 0),
        (N'Deploy the ASP.NET site', DATEADD(DAY, 30, GETDATE()), 'anonymous', 0);
END;
