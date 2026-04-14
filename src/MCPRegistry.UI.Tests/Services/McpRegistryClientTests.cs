using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using MCPRegistry.UI.Models;
using MCPRegistry.UI.Services;
using Moq;
using Moq.Protected;

namespace MCPRegistry.UI.Tests.Services;

public class McpRegistryClientTests
{
    private static McpRegistryClient CreateClient(HttpResponseMessage response)
    {
        var handler = new Mock<HttpMessageHandler>();
        handler.Protected()
            .Setup<Task<HttpResponseMessage>>("SendAsync",
                ItExpr.IsAny<HttpRequestMessage>(),
                ItExpr.IsAny<CancellationToken>())
            .ReturnsAsync(response);

        var http = new HttpClient(handler.Object) { BaseAddress = new Uri("https://test.api/") };
        return new McpRegistryClient(http);
    }

    private static HttpResponseMessage JsonResponse<T>(T data, HttpStatusCode status = HttpStatusCode.OK)
    {
        return new HttpResponseMessage(status)
        {
            Content = JsonContent.Create(data)
        };
    }

    // --- GetServersAsync ---

    [Fact]
    public async Task GetServersAsync_ReturnsServers()
    {
        var expected = new ServerListResponse
        {
            Servers = [new ServerResponseItem { Server = new ServerDetail { Name = "com.test/a", Version = "1.0.0" } }],
            Metadata = new ServerListMetadata { Count = 1 }
        };
        var client = CreateClient(JsonResponse(expected));

        var result = await client.GetServersAsync();

        result.Servers.Should().HaveCount(1);
        result.Servers[0].Server.Name.Should().Be("com.test/a");
    }

    [Fact]
    public async Task GetServersAsync_ReturnsEmptyList()
    {
        var expected = new ServerListResponse();
        var client = CreateClient(JsonResponse(expected));

        var result = await client.GetServersAsync();

        result.Servers.Should().BeEmpty();
    }

    [Fact]
    public async Task GetServersAsync_PassesSearchParam()
    {
        HttpRequestMessage? captured = null;
        var handler = new Mock<HttpMessageHandler>();
        handler.Protected()
            .Setup<Task<HttpResponseMessage>>("SendAsync",
                ItExpr.IsAny<HttpRequestMessage>(),
                ItExpr.IsAny<CancellationToken>())
            .Callback<HttpRequestMessage, CancellationToken>((req, _) => captured = req)
            .ReturnsAsync(JsonResponse(new ServerListResponse()));

        var http = new HttpClient(handler.Object) { BaseAddress = new Uri("https://test.api/") };
        var client = new McpRegistryClient(http);

        await client.GetServersAsync("azure");

        captured.Should().NotBeNull();
        captured!.RequestUri!.Query.Should().Contain("search=azure");
    }

    // --- GetServerVersionsAsync ---

    [Fact]
    public async Task GetServerVersionsAsync_ReturnsVersions()
    {
        var expected = new ServerListResponse
        {
            Servers =
            [
                new ServerResponseItem { Server = new ServerDetail { Name = "com.test/a", Version = "1.0.0" } },
                new ServerResponseItem { Server = new ServerDetail { Name = "com.test/a", Version = "2.0.0" } }
            ],
            Metadata = new ServerListMetadata { Count = 2 }
        };
        var client = CreateClient(JsonResponse(expected));

        var result = await client.GetServerVersionsAsync("com.test/a");

        result.Servers.Should().HaveCount(2);
    }

    [Fact]
    public async Task GetServerVersionsAsync_EncodesServerName()
    {
        HttpRequestMessage? captured = null;
        var handler = new Mock<HttpMessageHandler>();
        handler.Protected()
            .Setup<Task<HttpResponseMessage>>("SendAsync",
                ItExpr.IsAny<HttpRequestMessage>(),
                ItExpr.IsAny<CancellationToken>())
            .Callback<HttpRequestMessage, CancellationToken>((req, _) => captured = req)
            .ReturnsAsync(JsonResponse(new ServerListResponse()));

        var http = new HttpClient(handler.Object) { BaseAddress = new Uri("https://test.api/") };
        var client = new McpRegistryClient(http);

        await client.GetServerVersionsAsync("com.test/server");

        captured!.RequestUri!.AbsolutePath.Should().Contain("com.test/server");
    }

    // --- AddServersAsync ---

    [Fact]
    public async Task AddServersAsync_ReturnsTrue_OnSuccess()
    {
        var client = CreateClient(new HttpResponseMessage(HttpStatusCode.Created));

        var result = await client.AddServersAsync([new ServerDetail { Name = "com.test/a", Version = "1.0.0" }]);

        result.Should().BeTrue();
    }

    [Fact]
    public async Task AddServersAsync_ReturnsFalse_OnFailure()
    {
        var client = CreateClient(new HttpResponseMessage(HttpStatusCode.InternalServerError));

        var result = await client.AddServersAsync([new ServerDetail { Name = "com.test/a", Version = "1.0.0" }]);

        result.Should().BeFalse();
    }

    [Fact]
    public async Task AddServersAsync_SendsPostRequest()
    {
        HttpRequestMessage? captured = null;
        var handler = new Mock<HttpMessageHandler>();
        handler.Protected()
            .Setup<Task<HttpResponseMessage>>("SendAsync",
                ItExpr.IsAny<HttpRequestMessage>(),
                ItExpr.IsAny<CancellationToken>())
            .Callback<HttpRequestMessage, CancellationToken>((req, _) => captured = req)
            .ReturnsAsync(new HttpResponseMessage(HttpStatusCode.Created));

        var http = new HttpClient(handler.Object) { BaseAddress = new Uri("https://test.api/") };
        var client = new McpRegistryClient(http);

        await client.AddServersAsync([new ServerDetail { Name = "com.test/a", Version = "1.0.0" }]);

        captured!.Method.Should().Be(HttpMethod.Post);
        captured.RequestUri!.AbsolutePath.Should().Contain("v0.1/servers");
    }

    // --- DeleteServerVersionAsync ---

    [Fact]
    public async Task DeleteServerVersionAsync_ReturnsTrue_OnSuccess()
    {
        var client = CreateClient(new HttpResponseMessage(HttpStatusCode.OK));

        var result = await client.DeleteServerVersionAsync("com.test/a", "1.0.0");

        result.Should().BeTrue();
    }

    [Fact]
    public async Task DeleteServerVersionAsync_ReturnsFalse_OnNotFound()
    {
        var client = CreateClient(new HttpResponseMessage(HttpStatusCode.NotFound));

        var result = await client.DeleteServerVersionAsync("com.test/a", "9.9.9");

        result.Should().BeFalse();
    }

    [Fact]
    public async Task DeleteServerVersionAsync_SendsDeleteRequest()
    {
        HttpRequestMessage? captured = null;
        var handler = new Mock<HttpMessageHandler>();
        handler.Protected()
            .Setup<Task<HttpResponseMessage>>("SendAsync",
                ItExpr.IsAny<HttpRequestMessage>(),
                ItExpr.IsAny<CancellationToken>())
            .Callback<HttpRequestMessage, CancellationToken>((req, _) => captured = req)
            .ReturnsAsync(new HttpResponseMessage(HttpStatusCode.OK));

        var http = new HttpClient(handler.Object) { BaseAddress = new Uri("https://test.api/") };
        var client = new McpRegistryClient(http);

        await client.DeleteServerVersionAsync("com.test/server", "1.0.0");

        captured!.Method.Should().Be(HttpMethod.Delete);
        captured.RequestUri!.AbsolutePath.Should().Contain("com.test/server");
        captured.RequestUri.AbsolutePath.Should().Contain("1.0.0");
    }
}
