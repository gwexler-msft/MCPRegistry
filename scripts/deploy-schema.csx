using Microsoft.Data.SqlClient;

var token = args.Length > 0 ? args[0] : throw new ArgumentException("Pass access token as first argument");
var server = args.Length > 1 ? args[1] : throw new ArgumentException("Pass SQL server FQDN as second argument");
var database = args.Length > 2 ? args[2] : "MCPRegistry";

var connStr = $"Server=tcp:{server},1433;Database={database};Encrypt=True;TrustServerCertificate=False;";
using var conn = new SqlConnection(connStr);
conn.AccessToken = token;
conn.Open();
Console.WriteLine("Connected to Azure SQL");

var schemas = new[]
{
    """
    IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Servers')
    BEGIN
        CREATE TABLE Servers (
            ServerName NVARCHAR(255) NOT NULL,
            [Version] NVARCHAR(255) NOT NULL,
            [Status] NVARCHAR(50) NOT NULL DEFAULT 'active',
            AddedAt DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
            UpdatedAt DATETIMEOFFSET NOT NULL DEFAULT SYSDATETIMEOFFSET(),
            IsLatest BIT NOT NULL DEFAULT 1,
            [Value] NVARCHAR(MAX) NULL,
            CONSTRAINT PK_Servers PRIMARY KEY (ServerName, [Version]),
            CONSTRAINT CHK_Servers_Status CHECK ([Status] IN ('active', 'deprecated', 'deleted')),
            CONSTRAINT CHK_Servers_ServerNameFormat CHECK (ServerName LIKE '[a-zA-Z0-9]%/[a-zA-Z0-9]%'),
            CONSTRAINT CHK_Servers_VersionNotEmpty CHECK (LEN(LTRIM(RTRIM([Version]))) > 0)
        );
        PRINT 'Table created';
    END
    ELSE PRINT 'Table already exists';
    """,
    """
    SET QUOTED_IDENTIFIER ON;
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_Servers_ServerName')
        CREATE INDEX IDX_Servers_ServerName ON Servers(ServerName);
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_Servers_ServerNameVersion')
        CREATE INDEX IDX_Servers_ServerNameVersion ON Servers(ServerName, [Version]);
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_Servers_ServerNameLatest')
        CREATE INDEX IDX_Servers_ServerNameLatest ON Servers(ServerName, IsLatest) WHERE IsLatest = 1;
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IDX_Servers_Status')
        CREATE INDEX IDX_Servers_Status ON Servers([Status]);
    PRINT 'Indexes created';
    """,
    """
    IF NOT EXISTS (SELECT 1 FROM sys.triggers WHERE name = 'TRG_Servers_UpdateUpdatedAt')
    BEGIN
        EXEC('CREATE TRIGGER TRG_Servers_UpdateUpdatedAt ON Servers AFTER UPDATE AS
        BEGIN
            UPDATE Servers SET UpdatedAt = SYSDATETIMEOFFSET()
            FROM Inserted WHERE Servers.ServerName = Inserted.ServerName AND Servers.Version = Inserted.Version;
        END');
        PRINT 'Trigger created';
    END
    ELSE PRINT 'Trigger already exists';
    """
};

foreach (var sql in schemas)
{
    using var cmd = new SqlCommand(sql, conn);
    cmd.ExecuteNonQuery();
    Console.WriteLine("Executed schema step");
}

Console.WriteLine("Schema deployment complete");
