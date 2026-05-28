using MCPRegistry.UI.Services;
using Azure.Identity;
using Azure.Extensions.AspNetCore.DataProtection.Blobs;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Identity.Web;
using Microsoft.Identity.Web.UI;

var builder = WebApplication.CreateBuilder(args);

// Container Apps ingress terminates TLS and forwards as HTTP via X-Forwarded-Proto.
// Without this, Microsoft.Identity.Web builds the OIDC redirect_uri as http://
// and AAD rejects it (and the cookie SameSite=None;Secure won't survive either).
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto | ForwardedHeaders.XForwardedHost;
    options.KnownIPNetworks.Clear();
    options.KnownProxies.Clear();
});

builder.Services.AddRazorPages();

var dataProtectionBuilder = builder.Services.AddDataProtection()
    .SetApplicationName("MCPRegistry.UI");

var dataProtectionBlobUri = builder.Configuration["DataProtection:BlobUri"];
if (!string.IsNullOrWhiteSpace(dataProtectionBlobUri))
{
    // Persist OIDC state/cookies across container replacements so sign-in
    // callbacks can always unprotect message.State on the new revision.
    var credentialOptions = new DefaultAzureCredentialOptions();
    var managedIdentityClientId = builder.Configuration["AZURE_CLIENT_ID"];
    if (!string.IsNullOrWhiteSpace(managedIdentityClientId))
    {
        credentialOptions.ManagedIdentityClientId = managedIdentityClientId;
    }

    dataProtectionBuilder.PersistKeysToAzureBlobStorage(
        new Uri(dataProtectionBlobUri),
        new DefaultAzureCredential(credentialOptions));
}

builder.Services.AddHttpContextAccessor();
builder.Services.AddScoped<EasyAuthUser>();

// Wire OIDC + token acquisition only when AzureAd:ClientId is configured.
// Local dev (empty config) skips auth wiring so the UI runs anonymously
// against a local API that also has auth disabled.
var azureAdSection = builder.Configuration.GetSection("AzureAd");
var uiClientId = azureAdSection["ClientId"];
var apiAppClientId = azureAdSection["ApiAppClientId"];
var authConfigured = !string.IsNullOrWhiteSpace(uiClientId);
string? apiScope = null;

if (authConfigured)
{
    if (string.IsNullOrWhiteSpace(apiAppClientId))
    {
        throw new InvalidOperationException("AzureAd:ApiAppClientId is required when AzureAd:ClientId is set.");
    }

    apiScope = $"api://{apiAppClientId}/.default";

    builder.Services
        .AddAuthentication(OpenIdConnectDefaults.AuthenticationScheme)
        .AddMicrosoftIdentityWebApp(azureAdSection)
        .EnableTokenAcquisitionToCallDownstreamApi(new[] { apiScope })
        .AddInMemoryTokenCaches();

    builder.Services.AddAuthorization();

    builder.Services.AddControllersWithViews()
        .AddMicrosoftIdentityUI();
}
else
{
    builder.Services.AddAuthorization();
    builder.Services.AddControllersWithViews();
}

var apiBaseUrl = builder.Configuration["ApiBaseUrl"]
    ?? throw new InvalidOperationException("Configuration value 'ApiBaseUrl' is required but was not found.");

// McpRegistryClient reads the signed-in user via IHttpContextAccessor so it
// works inside Razor Pages (no Blazor circuit needed).
builder.Services.AddHttpClient<McpRegistryClient>(client =>
{
    client.BaseAddress = new Uri(apiBaseUrl.TrimEnd('/') + "/");
})
.AddTypedClient((http, sp) => authConfigured
    ? new McpRegistryClient(
        http,
        sp.GetRequiredService<ITokenAcquisition>(),
        sp.GetRequiredService<IHttpContextAccessor>(),
        apiScope)
    : new McpRegistryClient(http));

builder.Services.AddSingleton<ServerTemplateService>();

var app = builder.Build();
var requestTraceLogger = app.Services.GetRequiredService<ILoggerFactory>().CreateLogger("RequestTrace");

// Honor X-Forwarded-* headers from the Container Apps ingress before any
// middleware reads HttpContext.Request.Scheme (auth, antiforgery, etc.).
app.UseForwardedHeaders();

app.Use(async (context, next) =>
{
    await next();

    var path = context.Request.Path;
    if (path.StartsWithSegments("/signin-oidc") ||
        path.StartsWithSegments("/MicrosoftIdentity") ||
        path == "/")
    {
        requestTraceLogger.LogInformation(
            "{Method} {Path} => {StatusCode} (Auth={IsAuthenticated})",
            context.Request.Method,
            path,
            context.Response.StatusCode,
            context.User.Identity?.IsAuthenticated == true);
    }
});

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error", createScopeForErrors: true);
}
app.UseStatusCodePages(async statusCodeContext =>
{
    var response = statusCodeContext.HttpContext.Response;
    if (response.StatusCode == StatusCodes.Status404NotFound)
    {
        response.Redirect("/not-found");
    }
});

if (authConfigured)
{
    app.UseAuthentication();
}
app.UseAuthorization();

app.UseAntiforgery();

app.MapStaticAssets();
app.MapRazorPages();

if (authConfigured)
{
    app.MapControllers();
}

app.Run();

