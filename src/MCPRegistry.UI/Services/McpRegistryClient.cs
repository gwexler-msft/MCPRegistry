using System.Net.Http.Headers;
using System.Net.Http.Json;
using MCPRegistry.UI.Models;
using Microsoft.AspNetCore.Http;
using Microsoft.Identity.Web;

namespace MCPRegistry.UI.Services;

public class McpRegistryClient
{
    private readonly HttpClient _http;
    private readonly ITokenAcquisition? _tokenAcquisition;
    private readonly IHttpContextAccessor? _httpContextAccessor;
    private readonly string? _apiScope;

    public McpRegistryClient(HttpClient http)
        : this(http, null, null, null)
    {
    }

    public McpRegistryClient(
        HttpClient http,
        ITokenAcquisition? tokenAcquisition,
        IHttpContextAccessor? httpContextAccessor,
        string? apiScope)
    {
        _http = http;
        _tokenAcquisition = tokenAcquisition;
        _httpContextAccessor = httpContextAccessor;
        _apiScope = apiScope;
    }

    public async Task<ServerListResponse> GetServersAsync(string? search = null)
    {
        var url = "v0.1/servers";
        if (!string.IsNullOrWhiteSpace(search))
            url += $"?search={Uri.EscapeDataString(search)}";

        using var request = await CreateRequestAsync(HttpMethod.Get, url);
        using var response = await _http.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<ServerListResponse>() ?? new ServerListResponse();
    }

    public async Task<ServerListResponse> GetServerVersionsAsync(string serverName)
    {
        using var request = await CreateRequestAsync(HttpMethod.Get, $"v0.1/servers/{serverName}/versions");
        using var response = await _http.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<ServerListResponse>() ?? new ServerListResponse();
    }

    public async Task<(bool Success, string? Error)> AddServersAsync(List<ServerDetail> servers)
    {
        using var request = await CreateRequestAsync(HttpMethod.Post, "v0.1/servers");
        request.Content = JsonContent.Create(servers);
        using var response = await _http.SendAsync(request);
        if (response.IsSuccessStatusCode)
        {
            return (true, null);
        }
        var body = await response.Content.ReadAsStringAsync();
        return (false, $"{(int)response.StatusCode} {response.ReasonPhrase}: {body}");
    }

    public async Task<bool> DeleteServerVersionAsync(string serverName, string version)
    {
        using var request = await CreateRequestAsync(HttpMethod.Delete, $"v0.1/servers/{serverName}/versions/{version}");
        using var response = await _http.SendAsync(request);
        return response.IsSuccessStatusCode;
    }

    private async Task<HttpRequestMessage> CreateRequestAsync(HttpMethod method, string url)
    {
        var request = new HttpRequestMessage(method, url);
        if (_tokenAcquisition is null || _httpContextAccessor is null || string.IsNullOrEmpty(_apiScope))
        {
            return request;
        }

        // Registry reads are anonymous per spec; no token needed for GETs.
        if (method == HttpMethod.Get)
        {
            return request;
        }

        var user = _httpContextAccessor.HttpContext?.User;
        if (user?.Identity?.IsAuthenticated == true)
        {
            try
            {
                var token = await _tokenAcquisition.GetAccessTokenForUserAsync(
                    new[] { _apiScope },
                    user: user);
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            }
            catch (Microsoft.Identity.Client.MsalUiRequiredException)
            {
                // Swallow — caller surfaces the resulting 401 to the user.
            }
        }

        return request;
    }
}
