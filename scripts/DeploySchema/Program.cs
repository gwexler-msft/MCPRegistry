using Microsoft.Data.SqlClient;

var server = Environment.GetEnvironmentVariable("SQL_SERVER") ?? throw new Exception("SQL_SERVER env var required");
var database = Environment.GetEnvironmentVariable("SQL_DB") ?? "MCPRegistry";
var identityName = Environment.GetEnvironmentVariable("SQL_IDENTITY");

var connStr = $"Server=tcp:{server},1433;Database={database};Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=True;Connection Timeout=60;ConnectRetryCount=3;ConnectRetryInterval=10;";
using var conn = new SqlConnection(connStr);
conn.Open();
Console.WriteLine("Connected to Azure SQL");

string[] schemas =
[
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
    END
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
    """,
    """
    IF NOT EXISTS (SELECT 1 FROM sys.triggers WHERE name = 'TRG_Servers_UpdateUpdatedAt')
    BEGIN
        EXEC('CREATE TRIGGER TRG_Servers_UpdateUpdatedAt ON Servers AFTER UPDATE AS
        BEGIN
            UPDATE Servers SET UpdatedAt = SYSDATETIMEOFFSET()
            FROM Inserted WHERE Servers.ServerName = Inserted.ServerName AND Servers.Version = Inserted.Version;
        END');
    END
    """
];

for (int i = 0; i < schemas.Length; i++)
{
    using var cmd = new SqlCommand(schemas[i], conn);
    cmd.ExecuteNonQuery();
    Console.WriteLine($"Schema step {i + 1}/{schemas.Length} complete");
}

if (!string.IsNullOrEmpty(identityName))
{
    var grantSql = $"""
        IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '{identityName}')
        BEGIN
            CREATE USER [{identityName}] FROM EXTERNAL PROVIDER;
        END
        ALTER ROLE db_datareader ADD MEMBER [{identityName}];
        ALTER ROLE db_datawriter ADD MEMBER [{identityName}];
        """;
    using var grantCmd = new SqlCommand(grantSql, conn);
    grantCmd.ExecuteNonQuery();
    Console.WriteLine($"Granted db_datareader + db_datawriter to {identityName}");
}

Console.WriteLine("Done");
