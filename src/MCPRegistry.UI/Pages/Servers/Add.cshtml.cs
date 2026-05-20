using MCPRegistry.UI.Models;
using MCPRegistry.UI.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace MCPRegistry.UI.Pages.Servers;

[Authorize]
public class AddModel : PageModel
{
    private readonly McpRegistryClient _api;
    private readonly EasyAuthUser _user;
    private readonly ServerTemplateService _templates;

    public AddModel(McpRegistryClient api, EasyAuthUser user, ServerTemplateService templates)
    {
        _api = api;
        _user = user;
        _templates = templates;
    }

    [BindProperty]
    public ServerInput Input { get; set; } = new();

    public List<ServerDetail> Templates { get; private set; } = [];

    public string? ErrorMessage { get; private set; }

    [TempData]
    public string? SuccessMessage { get; set; }

    public bool IsAdmin => _user.IsAdmin;

    public string? DisplayName => _user.DisplayName;

    public async Task OnGetAsync(string? template = null)
    {
        Templates = await _templates.GetTemplatesAsync();

        if (!string.IsNullOrWhiteSpace(template))
        {
            var match = Templates.FirstOrDefault(t => string.Equals(t.Name, template, StringComparison.OrdinalIgnoreCase));
            if (match is not null)
            {
                Input = ServerInput.FromTemplate(match);
            }
        }

        if (Input.Packages.Count == 0)
        {
            Input.Packages.Add(new PackageInput());
        }
    }

    public async Task<IActionResult> OnPostAsync()
    {
        Templates = await _templates.GetTemplatesAsync();

        if (!_user.IsAdmin)
        {
            ErrorMessage = "Admin access required.";
            return Page();
        }

        if (string.IsNullOrWhiteSpace(Input.Name) || string.IsNullOrWhiteSpace(Input.Version))
        {
            ErrorMessage = "Name and Version are required.";
            return Page();
        }

        var detail = Input.ToServerDetail();
        var (ok, error) = await _api.AddServersAsync(new List<ServerDetail> { detail });
        if (!ok)
        {
            ErrorMessage = error ?? "Failed to add server.";
            return Page();
        }

        TempData["SuccessMessage"] = $"Added {Input.Name} {Input.Version}.";
        return RedirectToPage("/Index");
    }
}

public class ServerInput
{
    public string? Name { get; set; }
    public string? Version { get; set; }
    public string? Title { get; set; }
    public string? Description { get; set; }
    public string? WebsiteUrl { get; set; }
    public string? RepoUrl { get; set; }
    public string? RepoSource { get; set; }
    public string? RepoSubfolder { get; set; }
    public List<PackageInput> Packages { get; set; } = new();
    public List<RemoteInput> Remotes { get; set; } = new();

    public static ServerInput FromTemplate(ServerDetail t) => new()
    {
        Name = t.Name,
        Version = t.Version,
        Title = t.Title,
        Description = t.Description,
        WebsiteUrl = t.WebsiteUrl,
        RepoUrl = t.Repository?.Url,
        RepoSource = t.Repository?.Source,
        RepoSubfolder = t.Repository?.Subfolder,
        Packages = (t.Packages ?? new()).Select(p => new PackageInput
        {
            RegistryType = p.RegistryType,
            Identifier = p.Identifier,
            Version = p.Version,
            RuntimeHint = p.RuntimeHint,
            TransportType = p.Transport?.Type ?? "stdio",
        }).ToList(),
        Remotes = (t.Remotes ?? new()).Select(r => new RemoteInput
        {
            Type = r.Type,
            Url = r.Url,
        }).ToList(),
    };

    public ServerDetail ToServerDetail()
    {
        var detail = new ServerDetail
        {
            Name = Name ?? string.Empty,
            Version = Version ?? string.Empty,
            Title = string.IsNullOrWhiteSpace(Title) ? null : Title,
            Description = string.IsNullOrWhiteSpace(Description) ? null : Description,
            WebsiteUrl = string.IsNullOrWhiteSpace(WebsiteUrl) ? null : WebsiteUrl,
        };

        if (!string.IsNullOrWhiteSpace(RepoUrl))
        {
            detail.Repository = new RepositoryInfo
            {
                Url = RepoUrl,
                Source = string.IsNullOrWhiteSpace(RepoSource) ? null : RepoSource,
                Subfolder = string.IsNullOrWhiteSpace(RepoSubfolder) ? null : RepoSubfolder,
            };
        }

        var pkgs = Packages
            .Where(p => !string.IsNullOrWhiteSpace(p.Identifier))
            .Select(p => new PackageInfo
            {
                RegistryType = p.RegistryType ?? "npm",
                Identifier = p.Identifier ?? string.Empty,
                Version = string.IsNullOrWhiteSpace(p.Version) ? null : p.Version,
                RuntimeHint = string.IsNullOrWhiteSpace(p.RuntimeHint) ? null : p.RuntimeHint,
                Transport = new TransportInfo
                {
                    Type = p.TransportType ?? "stdio",
                    TransportType = p.TransportType ?? "stdio",
                },
            }).ToList();
        if (pkgs.Count > 0)
        {
            detail.Packages = pkgs;
        }

        var remotes = Remotes
            .Where(r => !string.IsNullOrWhiteSpace(r.Url))
            .Select(r => new RemoteInfo
            {
                Type = r.Type ?? "streamable-http",
                TransportType = r.Type ?? "streamable-http",
                Url = r.Url ?? string.Empty,
            }).ToList();
        if (remotes.Count > 0)
        {
            detail.Remotes = remotes;
        }

        return detail;
    }
}

public class PackageInput
{
    public string? RegistryType { get; set; } = "npm";
    public string? Identifier { get; set; }
    public string? Version { get; set; }
    public string? RuntimeHint { get; set; }
    public string? TransportType { get; set; } = "stdio";
}

public class RemoteInput
{
    public string? Type { get; set; } = "streamable-http";
    public string? Url { get; set; }
}
