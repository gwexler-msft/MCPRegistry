using MCPRegistry.UI.Models;
using MCPRegistry.UI.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace MCPRegistry.UI.Pages;

[Authorize]
public class IndexModel : PageModel
{
    private readonly McpRegistryClient _api;
    private readonly EasyAuthUser _user;

    public IndexModel(McpRegistryClient api, EasyAuthUser user)
    {
        _api = api;
        _user = user;
    }

    [BindProperty(SupportsGet = true)]
    public string? Search { get; set; }

    public List<ServerResponseItem> Servers { get; private set; } = [];

    public string? ErrorMessage { get; private set; }

    [TempData]
    public string? SuccessMessage { get; set; }

    public bool IsAdmin => _user.IsAdmin;

    public async Task OnGetAsync()
    {
        await LoadAsync();
    }

    public async Task<IActionResult> OnPostDeleteAsync(string serverName, string version)
    {
        if (!_user.IsAdmin)
        {
            ErrorMessage = "Admin access required.";
            await LoadAsync();
            return Page();
        }

        var ok = await _api.DeleteServerVersionAsync(serverName, version);
        SuccessMessage = ok
            ? $"Deleted {serverName} {version}."
            : null;
        if (!ok)
        {
            ErrorMessage = $"Failed to delete {serverName} {version}.";
        }
        return RedirectToPage(new { search = Search });
    }

    private async Task LoadAsync()
    {
        try
        {
            var result = await _api.GetServersAsync(Search);
            Servers = result.Servers;
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Failed to load servers: {ex.Message}";
        }
    }

    public static string TruncateText(string? text, int maxLength)
    {
        if (string.IsNullOrEmpty(text)) return "—";
        return text.Length <= maxLength ? text : text[..maxLength] + "...";
    }
}
