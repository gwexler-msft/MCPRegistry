using MCPRegistry.Models;

namespace MCPRegistry.Services;

public interface IServerRegistryService
{
    Task<(List<ServerDetail> servers, string? nextCursor)> GetServersAsync(
        string? cursor,
        int? limit,
        string? search,
        DateTime? updatedSince,
        string? version);

    Task<List<ServerDetail>> GetServerVersionsAsync(string serverName);

    Task<ServerDetail?> GetServerVersionAsync(string serverName, string version);

    Task<bool> DeleteServerVersionAsync(string serverName, string version);

    Task AddServerAsync(ServerDetail server);
}