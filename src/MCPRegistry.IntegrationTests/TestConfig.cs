namespace MCPRegistry.IntegrationTests;

/// <summary>
/// Reads the configuration that drives the integration tests from
/// environment variables (or azd env values exported via
/// <c>azd env get-values | ForEach-Object { $_ -replace '"','' } | Out-Host</c>).
/// </summary>
/// <remarks>
/// Required for any test to run:
/// <list type="bullet">
///   <item><c>MCPREG_API_URL</c> — base URL (e.g. <c>https://ca-mcpreg-xxx.<env>.azurecontainerapps.io</c>)</item>
///   <item><c>MCPREG_API_APP_CLIENT_ID</c> — AAD app reg client ID of <c>mcp-registry-api</c></item>
///   <item><c>MCPREG_TENANT_ID</c> — AAD tenant ID</item>
/// </list>
/// Optional:
/// <list type="bullet">
///   <item><c>MCPREG_ADMIN_GROUP_ID</c> — object ID of the admin group; enables the admin/non-admin policy assertions</item>
/// </list>
/// Tests check <see cref="IsConfigured"/> and call <see cref="Skip.IfNot"/> so they no-op when run on a dev box without the env vars set.
/// </remarks>
internal static class TestConfig
{
    public static string? ApiBaseUrl => Environment.GetEnvironmentVariable("MCPREG_API_URL");
    public static string? ApiAppClientId => Environment.GetEnvironmentVariable("MCPREG_API_APP_CLIENT_ID");
    public static string? TenantId => Environment.GetEnvironmentVariable("MCPREG_TENANT_ID");
    public static string? AdminGroupId => Environment.GetEnvironmentVariable("MCPREG_ADMIN_GROUP_ID");

    public static bool IsConfigured =>
        !string.IsNullOrWhiteSpace(ApiBaseUrl) &&
        !string.IsNullOrWhiteSpace(ApiAppClientId) &&
        !string.IsNullOrWhiteSpace(TenantId);

    public static string ApiScope => $"api://{ApiAppClientId}/.default";

    public const string SkipReason =
        "Integration tests require deployed infra. Set MCPREG_API_URL, MCPREG_API_APP_CLIENT_ID, " +
        "and MCPREG_TENANT_ID to run them (typically via `azd env get-values`). " +
        "These tests are skipped by default in local/CI dotnet test runs.";
}
