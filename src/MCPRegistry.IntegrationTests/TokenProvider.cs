using Azure.Core;
using Azure.Identity;

namespace MCPRegistry.IntegrationTests;

/// <summary>
/// Wraps a singleton <see cref="DefaultAzureCredential"/> so each test class
/// only goes through token cache lookup once per process. Uses the tenant ID
/// from <see cref="TestConfig"/> to disambiguate when the caller is signed in
/// to multiple tenants.
/// </summary>
internal static class TokenProvider
{
    private static readonly Lazy<DefaultAzureCredential> _credential = new(() =>
        new DefaultAzureCredential(new DefaultAzureCredentialOptions
        {
            TenantId = TestConfig.TenantId,
            // ExcludeManagedIdentityCredential is left enabled because integration
            // tests usually run from a developer laptop. If you want to run these
            // inside a Container App / VM with a user-assigned MI that has been
            // granted the mcp.access scope, remove this line.
            ExcludeManagedIdentityCredential = false,
        }));

    public static async Task<string> GetAccessTokenAsync(CancellationToken cancellationToken = default)
    {
        var token = await _credential.Value.GetTokenAsync(
            new TokenRequestContext(new[] { TestConfig.ApiScope }),
            cancellationToken);
        return token.Token;
    }
}
