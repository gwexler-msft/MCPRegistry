using System.Security.Claims;
using Microsoft.AspNetCore.Http;

namespace MCPRegistry.UI.Services;

/// <summary>
/// Surfaces the currently signed-in user. Reads HttpContext.User so it works in
/// Razor Pages and middleware without depending on a Blazor circuit.
/// </summary>
public class EasyAuthUser
{
    private readonly IHttpContextAccessor _httpContextAccessor;
    private readonly string? _adminGroupId;

    public EasyAuthUser(IHttpContextAccessor httpContextAccessor, IConfiguration config)
    {
        _httpContextAccessor = httpContextAccessor;
        _adminGroupId = config["AzureAd:AdminGroupId"];
    }

    public ClaimsPrincipal? Principal => _httpContextAccessor.HttpContext?.User;

    public bool IsAuthenticated => Principal?.Identity?.IsAuthenticated == true;

    public string? DisplayName =>
        Principal?.FindFirst("name")?.Value
            ?? Principal?.FindFirst(ClaimTypes.Name)?.Value
            ?? Principal?.FindFirst("preferred_username")?.Value;

    public bool IsAdmin
    {
        get
        {
            if (string.IsNullOrWhiteSpace(_adminGroupId) || Principal is null)
            {
                return false;
            }

            // Group object IDs flow in via the 'groups' claim configured as an
            // optional claim on the API app registration.
            return Principal.FindAll("groups").Any(c => string.Equals(c.Value, _adminGroupId, StringComparison.OrdinalIgnoreCase));
        }
    }
}

