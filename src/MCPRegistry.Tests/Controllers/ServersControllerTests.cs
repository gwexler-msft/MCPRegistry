using FluentAssertions;
using MCPRegistry.Controllers;
using MCPRegistry.Models;
using MCPRegistry.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;
using Moq;

namespace MCPRegistry.Tests.Controllers;

public class ServersControllerTests
{
    private readonly Mock<IServerRegistryService> _mockService;
    private readonly Mock<ILogger<ServersController>> _mockLogger;
    private readonly ServersController _controller;

    public ServersControllerTests()
    {
        _mockService = new Mock<IServerRegistryService>();
        _mockLogger = new Mock<ILogger<ServersController>>();
        _controller = new ServersController(_mockService.Object, _mockLogger.Object);
    }

    private static ServerDetail CreateTestServer(string name = "com.test/server", string version = "1.0.0") => new()
    {
        Name = name,
        Version = version,
        Description = "Test server",
        Title = "Test Server",
        Status = "active",
        AddedAt = DateTimeOffset.UtcNow,
        UpdatedAt = DateTimeOffset.UtcNow,
        IsLatest = true
    };

    // --- ListServers ---

    [Fact]
    public async Task ListServers_ReturnsEmptyList_WhenNoServersExist()
    {
        _mockService.Setup(s => s.GetServersAsync(null, null, null, null, null))
            .ReturnsAsync((new List<ServerDetail>(), (string?)null));

        var result = await _controller.ListServers(null, null, null, null, null);

        var jsonResult = result.Result.Should().BeOfType<JsonResult>().Subject;
        var serverList = jsonResult.Value.Should().BeOfType<ServerList>().Subject;
        serverList.Servers.Should().BeEmpty();
        serverList.Metadata.Count.Should().Be(0);
    }

    [Fact]
    public async Task ListServers_ReturnsServers_WhenServersExist()
    {
        var servers = new List<ServerDetail> { CreateTestServer() };
        _mockService.Setup(s => s.GetServersAsync(null, null, null, null, null))
            .ReturnsAsync((servers, (string?)null));

        var result = await _controller.ListServers(null, null, null, null, null);

        var jsonResult = result.Result.Should().BeOfType<JsonResult>().Subject;
        var serverList = jsonResult.Value.Should().BeOfType<ServerList>().Subject;
        serverList.Servers.Should().HaveCount(1);
        serverList.Metadata.Count.Should().Be(1);
    }

    [Fact]
    public async Task ListServers_ReturnsBadRequest_WhenLimitIsZero()
    {
        var result = await _controller.ListServers(null, 0, null, null, null);

        result.Result.Should().BeOfType<BadRequestObjectResult>();
    }

    [Fact]
    public async Task ListServers_ReturnsBadRequest_WhenLimitIsNegative()
    {
        var result = await _controller.ListServers(null, -1, null, null, null);

        result.Result.Should().BeOfType<BadRequestObjectResult>();
    }

    [Theory]
    [InlineData("invalid")]
    [InlineData("1.2")]
    [InlineData("abc.def.ghi")]
    public async Task ListServers_ReturnsBadRequest_WhenVersionIsInvalidSemver(string version)
    {
        var result = await _controller.ListServers(null, null, null, null, version);

        result.Result.Should().BeOfType<BadRequestObjectResult>();
    }

    [Theory]
    [InlineData("latest")]
    [InlineData("1.0.0")]
    [InlineData("2.0.0-beta.6")]
    [InlineData("1.0.0+build.123")]
    public async Task ListServers_AcceptsValidVersionFormats(string version)
    {
        _mockService.Setup(s => s.GetServersAsync(null, null, null, null, version))
            .ReturnsAsync((new List<ServerDetail>(), (string?)null));

        var result = await _controller.ListServers(null, null, null, null, version);

        result.Result.Should().BeOfType<JsonResult>();
    }

    [Fact]
    public async Task ListServers_PassesSearchToService()
    {
        _mockService.Setup(s => s.GetServersAsync(null, null, "azure", null, null))
            .ReturnsAsync((new List<ServerDetail>(), (string?)null));

        await _controller.ListServers(null, null, "azure", null, null);

        _mockService.Verify(s => s.GetServersAsync(null, null, "azure", null, null), Times.Once);
    }

    [Fact]
    public async Task ListServers_Returns500_WhenServiceThrows()
    {
        _mockService.Setup(s => s.GetServersAsync(null, null, null, null, null))
            .ThrowsAsync(new Exception("DB error"));

        var result = await _controller.ListServers(null, null, null, null, null);

        var problemResult = result.Result.Should().BeOfType<ObjectResult>().Subject;
        problemResult.StatusCode.Should().Be(StatusCodes.Status500InternalServerError);
    }

    // --- ListServerVersions ---

    [Fact]
    public async Task ListServerVersions_ReturnsNotFound_WhenServerDoesNotExist()
    {
        _mockService.Setup(s => s.GetServerVersionsAsync("com.test/unknown"))
            .ReturnsAsync(new List<ServerDetail>());

        var result = await _controller.ListServerVersions("com.test", "unknown");

        result.Result.Should().BeOfType<NotFoundObjectResult>();
    }

    [Fact]
    public async Task ListServerVersions_ReturnsVersions_WhenServerExists()
    {
        var versions = new List<ServerDetail>
        {
            CreateTestServer(version: "1.0.0"),
            CreateTestServer(version: "2.0.0")
        };
        _mockService.Setup(s => s.GetServerVersionsAsync("com.test/server"))
            .ReturnsAsync(versions);

        var result = await _controller.ListServerVersions("com.test", "server");

        var jsonResult = result.Result.Should().BeOfType<JsonResult>().Subject;
        var serverList = jsonResult.Value.Should().BeOfType<ServerList>().Subject;
        serverList.Servers.Should().HaveCount(2);
        serverList.Metadata.Count.Should().Be(2);
    }

    [Fact]
    public async Task ListServerVersions_DecodesUrlEncodedServerName()
    {
        _mockService.Setup(s => s.GetServerVersionsAsync("com.test/server"))
            .ReturnsAsync(new List<ServerDetail> { CreateTestServer() });

        await _controller.ListServerVersions("com.test", "server");

        _mockService.Verify(s => s.GetServerVersionsAsync("com.test/server"), Times.Once);
    }

    // --- GetServerVersion ---

    [Fact]
    public async Task GetServerVersion_ReturnsNotFound_WhenVersionDoesNotExist()
    {
        _mockService.Setup(s => s.GetServerVersionAsync("com.test/server", "9.9.9"))
            .ReturnsAsync((ServerDetail?)null);

        var result = await _controller.GetServerVersion("com.test", "server", "9.9.9");

        result.Result.Should().BeOfType<NotFoundObjectResult>();
    }

    [Fact]
    public async Task GetServerVersion_ReturnsServer_WhenVersionExists()
    {
        var server = CreateTestServer();
        _mockService.Setup(s => s.GetServerVersionAsync("com.test/server", "1.0.0"))
            .ReturnsAsync(server);

        var result = await _controller.GetServerVersion("com.test", "server", "1.0.0");

        var jsonResult = result.Result.Should().BeOfType<JsonResult>().Subject;
        var response = jsonResult.Value.Should().BeOfType<ServerResponse>().Subject;
        response.Server.Name.Should().Be("com.test/server");
    }

    [Fact]
    public async Task GetServerVersion_IncludesMetadata()
    {
        var server = CreateTestServer();
        _mockService.Setup(s => s.GetServerVersionAsync("com.test/server", "1.0.0"))
            .ReturnsAsync(server);

        var result = await _controller.GetServerVersion("com.test", "server", "1.0.0");

        var jsonResult = result.Result.Should().BeOfType<JsonResult>().Subject;
        var response = jsonResult.Value.Should().BeOfType<ServerResponse>().Subject;
        response.Meta.Should().ContainKey("io.modelcontextprotocol.registry/official");
    }

    // --- DeleteServerVersion ---

    [Fact]
    public async Task DeleteServerVersion_ReturnsNotFound_WhenServerDoesNotExist()
    {
        _mockService.Setup(s => s.GetServerVersionAsync("com.test/server", "1.0.0"))
            .ReturnsAsync((ServerDetail?)null);

        var result = await _controller.DeleteServerVersion("com.test", "server", "1.0.0");

        result.Should().BeOfType<NotFoundObjectResult>();
    }

    [Fact]
    public async Task DeleteServerVersion_ReturnsOk_WhenDeleteSucceeds()
    {
        _mockService.Setup(s => s.GetServerVersionAsync("com.test/server", "1.0.0"))
            .ReturnsAsync(CreateTestServer());
        _mockService.Setup(s => s.DeleteServerVersionAsync("com.test/server", "1.0.0"))
            .ReturnsAsync(true);

        var result = await _controller.DeleteServerVersion("com.test", "server", "1.0.0");

        result.Should().BeOfType<OkResult>();
    }

    [Fact]
    public async Task DeleteServerVersion_Returns500_WhenDeleteFails()
    {
        _mockService.Setup(s => s.GetServerVersionAsync("com.test/server", "1.0.0"))
            .ReturnsAsync(CreateTestServer());
        _mockService.Setup(s => s.DeleteServerVersionAsync("com.test/server", "1.0.0"))
            .ReturnsAsync(false);

        var result = await _controller.DeleteServerVersion("com.test", "server", "1.0.0");

        var problemResult = result.Should().BeOfType<ObjectResult>().Subject;
        problemResult.StatusCode.Should().Be(StatusCodes.Status500InternalServerError);
    }

    // --- AddServers ---

    [Fact]
    public async Task AddServers_ReturnsBadRequest_WhenListIsEmpty()
    {
        var result = await _controller.AddServers(new List<ServerDetail>());

        result.Should().BeOfType<BadRequestObjectResult>();
    }

    [Fact]
    public async Task AddServers_ReturnsCreated_WhenServersAdded()
    {
        var servers = new List<ServerDetail> { CreateTestServer() };

        var result = await _controller.AddServers(servers);

        result.Should().BeOfType<CreatedResult>();
        _mockService.Verify(s => s.AddServerAsync(It.IsAny<ServerDetail>()), Times.Once);
    }

    [Fact]
    public async Task AddServers_CallsServiceForEachServer()
    {
        var servers = new List<ServerDetail>
        {
            CreateTestServer("com.test/a", "1.0.0"),
            CreateTestServer("com.test/b", "2.0.0")
        };

        await _controller.AddServers(servers);

        _mockService.Verify(s => s.AddServerAsync(It.IsAny<ServerDetail>()), Times.Exactly(2));
    }

    [Fact]
    public async Task AddServers_Returns500_WhenServiceThrows()
    {
        _mockService.Setup(s => s.AddServerAsync(It.IsAny<ServerDetail>()))
            .ThrowsAsync(new Exception("DB error"));

        var result = await _controller.AddServers(new List<ServerDetail> { CreateTestServer() });

        var problemResult = result.Should().BeOfType<ObjectResult>().Subject;
        problemResult.StatusCode.Should().Be(StatusCodes.Status500InternalServerError);
    }
}
