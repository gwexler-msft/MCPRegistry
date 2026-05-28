using MCPRegistry.Data;
using MCPRegistry.Services;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.Identity.Web;
using System.Text.Json.Serialization;

namespace MCPRegistry;

public class Program
{
    public static void Main(string[] args)
    {
        var builder = WebApplication.CreateBuilder(args);

        builder.Services.AddScoped<IServerRepository, SqlServerServerRepository>();
        builder.Services.AddScoped<IServerRegistryService, ServerRegistryService>();

        // Bind Entra ID config from the AzureAd: section (populated via env vars
        // in the container: AzureAd__TenantId, AzureAd__ClientId, AzureAd__AdminGroupId).
        // Microsoft.Identity.Web sets up JwtBearer to validate v2.0 tokens against
        // the AAD app registration created by the setup-aad-apps preprovision hook.
        var azureAdSection = builder.Configuration.GetSection("AzureAd");
        var apiAppClientId = azureAdSection["ClientId"];
        var adminGroupId = azureAdSection["AdminGroupId"];

        // Skip auth wiring when ClientId is empty (local dev without Entra).
        // In production the env var is always populated by Bicep.
        var authConfigured = !string.IsNullOrWhiteSpace(apiAppClientId);

        if (authConfigured)
        {
            builder.Services
                .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
                .AddMicrosoftIdentityWebApi(jwtOptions =>
                {
                    builder.Configuration.Bind("AzureAd", jwtOptions);
                    // Accept v2.0 tokens issued for the API app registration's
                    // resource URI (api://<appId>) and the bare appId form.
                    jwtOptions.TokenValidationParameters.ValidAudiences = new[]
                    {
                        $"api://{apiAppClientId}",
                        apiAppClientId!
                    };
                },
                msIdentityOptions =>
                {
                    builder.Configuration.Bind("AzureAd", msIdentityOptions);
                });

            builder.Services.AddAuthorization(options =>
            {
                // GET endpoints on ServersController are anonymous per the MCP
                // Registry v0.1 spec, so reads do not need a policy. Writes use
                // RequireAdmin: a valid token whose 'groups' claim contains the
                // configured admin group object ID. When the group list overflows
                // (>200), AAD emits a `_claim_names` overage claim instead and
                // we'd need Graph; that's a known follow-up.
                options.AddPolicy("RequireAdmin", policy =>
                {
                    policy.RequireAuthenticatedUser();
                    if (!string.IsNullOrWhiteSpace(adminGroupId))
                    {
                        policy.RequireClaim("groups", adminGroupId);
                    }
                });
            });
        }
        else
        {
            // No-op authorization for local dev (when running without Entra config).
            builder.Services.AddAuthorization(options =>
            {
                options.AddPolicy("RequireAdmin", policy => policy.RequireAssertion(_ => true));
            });
        }

        builder.Services.AddControllers()
            .AddJsonOptions(options =>
            {
                options.JsonSerializerOptions.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
                options.JsonSerializerOptions.PropertyNamingPolicy = null;
                options.JsonSerializerOptions.WriteIndented = false;
            });

        builder.Services.AddEndpointsApiExplorer();
        builder.Services.AddSwaggerGen();
        builder.Services.AddProblemDetails();
        builder.Services.AddCors(options =>
        {
            options.AddPolicy(Constants.CorsServersEndpointPolicy, policy =>
            {
                policy.AllowAnyOrigin()
                    .WithHeaders("Authorization, Content-Type")
                    .WithMethods("GET");
            });
        });

        var app = builder.Build();

        if (app.Environment.IsDevelopment())
        {
            app.UseSwagger();
            app.UseSwaggerUI();
        }

        app.UseHttpsRedirection();
        app.UseCors(Constants.CorsServersEndpointPolicy);

        if (authConfigured)
        {
            app.UseAuthentication();
        }
        app.UseAuthorization();
        app.MapControllers();

        app.Run();
    }
}
