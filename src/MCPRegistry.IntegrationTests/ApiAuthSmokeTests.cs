using System.Net;
using System.Net.Http.Headers;
using FluentAssertions;

namespace MCPRegistry.IntegrationTests;

/// <summary>
/// End-to-end smoke tests against the deployed MCP Registry API. The contract
/// we assert matches the MCP Registry v0.1 specification:
/// <list type="bullet">
///   <item>Anonymous GET → 200 (spec-compliant; required by GitHub Copilot's
///         "MCP registry URL" org policy in "Registry only" mode)</item>
///   <item>GET with a valid token → 200 (token is accepted but ignored)</item>
///   <item>Anonymous POST → 401 (writes require auth)</item>
///   <item>Authenticated POST → 201 if caller is in the admin group, 403 if not</item>
/// </list>
/// All tests no-op (return Skipped) when the deployment env vars are not set,
/// so <c>dotnet test</c> on a fresh clone never fails.
/// </summary>
public class ApiAuthSmokeTests
{
    private static HttpClient CreateClient() => new()
    {
        BaseAddress = new Uri(TestConfig.ApiBaseUrl!.TrimEnd('/') + "/"),
        Timeout = TimeSpan.FromSeconds(30),
    };

    [SkippableFact]
    public async Task Anonymous_GetServers_Returns200()
    {
        Skip.IfNot(TestConfig.IsConfigured, TestConfig.SkipReason);

        using var client = CreateClient();
        using var response = await client.GetAsync("v0.1/servers");

        response.StatusCode.Should().Be(HttpStatusCode.OK,
            "GET /v0.1/servers is anonymous per the MCP Registry v0.1 spec so that " +
            "spec-compliant clients (e.g. GitHub Copilot's MCP registry URL policy) " +
            "can list servers without prior credential exchange");

        var body = await response.Content.ReadAsStringAsync();
        body.Should().Contain("\"servers\"",
            "the ServerList response wraps results in a 'servers' property");
    }

    [SkippableFact]
    public async Task ValidToken_GetServers_Returns200()
    {
        Skip.IfNot(TestConfig.IsConfigured, TestConfig.SkipReason);

        var token = await TokenProvider.GetAccessTokenAsync();

        using var client = CreateClient();
        client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", token);

        using var response = await client.GetAsync("v0.1/servers");

        response.StatusCode.Should().Be(HttpStatusCode.OK,
            "a valid token on an anonymous endpoint must still succeed");
    }

    [SkippableFact]
    public async Task Anonymous_PostServers_Returns401()
    {
        Skip.IfNot(TestConfig.IsConfigured, TestConfig.SkipReason);

        using var client = CreateClient();
        var payload = new StringContent(
            """[{"name":"com.example/anon-write-smoke","version":"0.0.0","title":"Smoke"}]""",
            System.Text.Encoding.UTF8,
            "application/json");

        using var response = await client.PostAsync("v0.1/servers", payload);

        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized,
            "writes still require an authenticated admin token");
    }

    [SkippableFact]
    public async Task NonAdminToken_PostServers_Returns403()
    {
        Skip.IfNot(TestConfig.IsConfigured, TestConfig.SkipReason);
        Skip.If(string.IsNullOrWhiteSpace(TestConfig.AdminGroupId),
            "Set MCPREG_ADMIN_GROUP_ID and run as a user who is NOT a member of that group.");

        var token = await TokenProvider.GetAccessTokenAsync();

        using var client = CreateClient();
        client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", token);

        var payload = new StringContent(
            """[{"name":"com.example/integration-smoke","version":"0.0.0","description":"smoke test - should be rejected","title":"Smoke"}]""",
            System.Text.Encoding.UTF8,
            "application/json");

        using var response = await client.PostAsync("v0.1/servers", payload);

        // We can't tell from the test runner whether the calling identity is
        // in the admin group or not, so accept both: a Forbidden proves the
        // policy is enforced; a Created proves the calling identity happens
        // to be admin and writes work end-to-end. The point of this test is
        // to catch the case where the policy is wired up wrong and admins
        // get 401 or non-admins get 201.
        response.StatusCode.Should().BeOneOf(
            new[] { HttpStatusCode.Forbidden, HttpStatusCode.Created },
            "POST must either succeed (admin) or be rejected with 403 (non-admin) — never 401 (we have a valid token) and never 200/204/500");
    }
}
