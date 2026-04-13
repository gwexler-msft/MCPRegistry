using FluentAssertions;
using MCPRegistry.Data;
using MCPRegistry.Models;
using MCPRegistry.Services;
using Moq;

namespace MCPRegistry.Tests.Services;

public class ServerRegistryServiceTests
{
    private readonly Mock<IServerRepository> _mockRepo;
    private readonly ServerRegistryService _service;

    public ServerRegistryServiceTests()
    {
        _mockRepo = new Mock<IServerRepository>();
        _service = new ServerRegistryService(_mockRepo.Object);
    }

    private static ServerDetail CreateTestServer(string name = "com.test/server", string version = "1.0.0") => new()
    {
        Name = name,
        Version = version,
        Description = "Test",
        Status = "active",
        AddedAt = DateTimeOffset.UtcNow,
        UpdatedAt = DateTimeOffset.UtcNow,
        IsLatest = true
    };

    // --- GetServersAsync ---

    [Fact]
    public async Task GetServersAsync_DefaultsTo30PageSize()
    {
        _mockRepo.Setup(r => r.GetServersAsync(null, null, 30, null, null, null))
            .ReturnsAsync(new List<ServerDetail>());

        await _service.GetServersAsync(null, null, null, null, null);

        _mockRepo.Verify(r => r.GetServersAsync(null, null, 30, null, null, null), Times.Once);
    }

    [Fact]
    public async Task GetServersAsync_UsesProvidedLimit()
    {
        _mockRepo.Setup(r => r.GetServersAsync(null, null, 10, null, null, null))
            .ReturnsAsync(new List<ServerDetail>());

        await _service.GetServersAsync(null, 10, null, null, null);

        _mockRepo.Verify(r => r.GetServersAsync(null, null, 10, null, null, null), Times.Once);
    }

    [Fact]
    public async Task GetServersAsync_ParsesCompositeCursor()
    {
        _mockRepo.Setup(r => r.GetServersAsync("com.test/server", "1.0.0", 30, null, null, null))
            .ReturnsAsync(new List<ServerDetail>());

        await _service.GetServersAsync("com.test/server:1.0.0", null, null, null, null);

        _mockRepo.Verify(r => r.GetServersAsync("com.test/server", "1.0.0", 30, null, null, null), Times.Once);
    }

    [Fact]
    public async Task GetServersAsync_TreatsMalformedCursorAsServerNameOnly()
    {
        _mockRepo.Setup(r => r.GetServersAsync("malformed-cursor", null, 30, null, null, null))
            .ReturnsAsync(new List<ServerDetail>());

        await _service.GetServersAsync("malformed-cursor", null, null, null, null);

        _mockRepo.Verify(r => r.GetServersAsync("malformed-cursor", null, 30, null, null, null), Times.Once);
    }

    [Fact]
    public async Task GetServersAsync_ReturnsNextCursor_WhenPageIsFull()
    {
        var servers = Enumerable.Range(1, 30)
            .Select(i => CreateTestServer(version: $"{i}.0.0"))
            .ToList();
        _mockRepo.Setup(r => r.GetServersAsync(null, null, 30, null, null, null))
            .ReturnsAsync(servers);

        var (_, nextCursor) = await _service.GetServersAsync(null, null, null, null, null);

        nextCursor.Should().Be("com.test/server:30.0.0");
    }

    [Fact]
    public async Task GetServersAsync_ReturnsNullCursor_WhenPageIsNotFull()
    {
        var servers = new List<ServerDetail> { CreateTestServer() };
        _mockRepo.Setup(r => r.GetServersAsync(null, null, 30, null, null, null))
            .ReturnsAsync(servers);

        var (_, nextCursor) = await _service.GetServersAsync(null, null, null, null, null);

        nextCursor.Should().BeNull();
    }

    [Fact]
    public async Task GetServersAsync_PassesSearchAndFilters()
    {
        var updatedSince = new DateTime(2026, 1, 1);
        _mockRepo.Setup(r => r.GetServersAsync(null, null, 30, "azure", updatedSince, "latest"))
            .ReturnsAsync(new List<ServerDetail>());

        await _service.GetServersAsync(null, null, "azure", updatedSince, "latest");

        _mockRepo.Verify(r => r.GetServersAsync(null, null, 30, "azure", updatedSince, "latest"), Times.Once);
    }

    // --- GetServerVersionsAsync ---

    [Fact]
    public async Task GetServerVersionsAsync_DelegatesToRepository()
    {
        var versions = new List<ServerDetail> { CreateTestServer() };
        _mockRepo.Setup(r => r.GetServerVersionsAsync("com.test/server"))
            .ReturnsAsync(versions);

        var result = await _service.GetServerVersionsAsync("com.test/server");

        result.Should().BeEquivalentTo(versions);
    }

    [Fact]
    public async Task GetServerVersionsAsync_ReturnsEmpty_WhenServerNotFound()
    {
        _mockRepo.Setup(r => r.GetServerVersionsAsync("com.test/unknown"))
            .ReturnsAsync(new List<ServerDetail>());

        var result = await _service.GetServerVersionsAsync("com.test/unknown");

        result.Should().BeEmpty();
    }

    // --- GetServerVersionAsync ---

    [Fact]
    public async Task GetServerVersionAsync_ReturnsServer_WhenFound()
    {
        var server = CreateTestServer();
        _mockRepo.Setup(r => r.GetServerVersionAsync("com.test/server", "1.0.0"))
            .ReturnsAsync(server);

        var result = await _service.GetServerVersionAsync("com.test/server", "1.0.0");

        result.Should().NotBeNull();
        result!.Name.Should().Be("com.test/server");
    }

    [Fact]
    public async Task GetServerVersionAsync_ReturnsNull_WhenNotFound()
    {
        _mockRepo.Setup(r => r.GetServerVersionAsync("com.test/server", "9.9.9"))
            .ReturnsAsync((ServerDetail?)null);

        var result = await _service.GetServerVersionAsync("com.test/server", "9.9.9");

        result.Should().BeNull();
    }

    // --- DeleteServerVersionAsync ---

    [Fact]
    public async Task DeleteServerVersionAsync_ReturnsTrue_WhenDeleted()
    {
        _mockRepo.Setup(r => r.DeleteServerVersionAsync("com.test/server", "1.0.0"))
            .ReturnsAsync(true);

        var result = await _service.DeleteServerVersionAsync("com.test/server", "1.0.0");

        result.Should().BeTrue();
    }

    [Fact]
    public async Task DeleteServerVersionAsync_ReturnsFalse_WhenNotFound()
    {
        _mockRepo.Setup(r => r.DeleteServerVersionAsync("com.test/server", "9.9.9"))
            .ReturnsAsync(false);

        var result = await _service.DeleteServerVersionAsync("com.test/server", "9.9.9");

        result.Should().BeFalse();
    }

    // --- AddServerAsync ---

    [Fact]
    public async Task AddServerAsync_DelegatesToRepository()
    {
        var server = CreateTestServer();

        await _service.AddServerAsync(server);

        _mockRepo.Verify(r => r.AddServerAsync(server), Times.Once);
    }
}
