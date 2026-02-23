using Microsoft.AspNetCore.Mvc;
using System.Security.Cryptography.X509Certificates;
using OsmUserWeb.Models;
using OsmUserWeb.Services;

var builder = WebApplication.CreateBuilder(args);

// Enables clean start/stop lifecycle and Event Log integration when hosted as a Windows Service.
// Has no effect when running interactively (dotnet run / Start-OsmUserWeb.ps1).
builder.Host.UseWindowsService(options => options.ServiceName = "OsmUserWeb");

builder.Services.Configure<AdSettings>(builder.Configuration.GetSection("AdSettings"));
builder.Services.AddScoped<AdUserService>();

// Load TLS certificate from PFX file using EphemeralKeySet so the private key is kept
// in memory only.  This avoids the "Access denied" failure that occurs when the service
// account (e.g. svc-osmweb) has no loaded user profile and .NET tries to persist the
// key to the per-user key store.  Falls back to the standard Kestrel configuration
// (appsettings Kestrel:Endpoints) when TlsCertificate:Path is absent or the file does
// not exist.
var pfxPath     = builder.Configuration["TlsCertificate:Path"];
var pfxPassword = builder.Configuration["TlsCertificate:Password"];
if (!string.IsNullOrEmpty(pfxPath) && File.Exists(pfxPath))
{
    var cert = X509CertificateLoader.LoadPkcs12FromFile(pfxPath, pfxPassword,
        X509KeyStorageFlags.EphemeralKeySet);
    builder.WebHost.ConfigureKestrel(k =>
        k.ConfigureHttpsDefaults(h => h.ServerCertificate = cert));
}

var app = builder.Build();

app.UseDefaultFiles();   // serves index.html for "/"
app.UseStaticFiles();

// ── GET /api/preview?baseName={baseName} ──────────────────────────────────────
// Returns the next auto-incremented username and a summary of what will be created.
app.MapGet("/api/preview", (
    [FromQuery] string? baseName,
    AdUserService svc) =>
{
    try
    {
        return Results.Ok(svc.GetPreview(baseName));
    }
    catch (ArgumentException ex)
    {
        return Results.Problem(ex.Message, statusCode: StatusCodes.Status400BadRequest);
    }
    catch (InvalidOperationException ex)
    {
        return Results.Problem(ex.Message, statusCode: StatusCodes.Status422UnprocessableEntity);
    }
    catch (Exception ex)
    {
        return Results.Problem(ex.Message, statusCode: StatusCodes.Status500InternalServerError);
    }
});

// ── POST /api/users ───────────────────────────────────────────────────────────
// Creates the AD account. Returns 201 with the verified user details on success.
app.MapPost("/api/users", (
    [FromBody] CreateUserRequest request,
    AdUserService svc) =>
{
    try
    {
        var created = svc.CreateUser(request.BaseName, request.Password);
        return Results.Created($"/api/users/{created.SamAccountName}", created);
    }
    catch (ArgumentException ex)
    {
        return Results.Problem(ex.Message, statusCode: StatusCodes.Status400BadRequest);
    }
    catch (InvalidOperationException ex)
    {
        return Results.Problem(ex.Message, statusCode: StatusCodes.Status409Conflict);
    }
    catch (Exception ex)
    {
        return Results.Problem(ex.Message, statusCode: StatusCodes.Status500InternalServerError);
    }
});

app.Run();
