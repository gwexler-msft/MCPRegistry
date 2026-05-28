using MCPRegistry.UI.Models;
using MCPRegistry.UI.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace MCPRegistry.UI.Pages.Servers;

[Authorize]
public class VersionsModel : PageModel
{
    private readonly McpRegistryClient _api;
    private readonly EasyAuthUser _user;

    public VersionsModel(McpRegistryClient api, EasyAuthUser user)
    {
        _api = api;
        _user = user;
    }

    [BindProperty(SupportsGet = true)]
    public string ServerName { get; set; } = string.Empty;

    public List<ServerResponseItem> Versions { get; private set; } = [];

    public string? ErrorMessage { get; private set; }

    [TempData]
    public string? SuccessMessage { get; set; }

    public bool IsAdmin => _user.IsAdmin;

    public async Task OnGetAsync()
    {
        await LoadAsync();
    }

    public async Task<IActionResult> OnPostDeleteAsync(string version)
    {
        if (!_user.IsAdmin)
        {
            ErrorMessage = "Admin access required.";
            await LoadAsync();
            return Page();
        }

        var ok = await _api.DeleteServerVersionAsync(ServerName, version);
        if (ok)
        {
            SuccessMessage = $"Deleted {ServerName} {version}.";
        }
        else
        {
            ErrorMessage = $"Failed to delete {ServerName} {version}.";
        }
        return RedirectToPage(new { serverName = ServerName });
    }

    private async Task LoadAsync()
    {
        try
        {
            var result = await _api.GetServerVersionsAsync(ServerName);
            Versions = result.Servers;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Failed to load versions: {ex.Message}";
        }
    }
}
