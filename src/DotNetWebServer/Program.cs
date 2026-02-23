using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Server.HttpSys;
using OsmUserWeb.Models;
using OsmUserWeb.Services;

var builder = WebApplication.CreateBuilder(args);

// Enables clean start/stop lifecycle and Event Log integration when hosted as a Windows Service.
// Has no effect when running interactively (dotnet run / Start-OsmUserWeb.ps1).
builder.Host.UseWindowsService(options => options.ServiceName = "OsmUserWeb");

// Use the Windows HTTP.sys kernel driver for all HTTP/HTTPS traffic.
// HTTP.sys handles TLS termination in kernel mode (as SYSTEM), so the service
// account (svc-osmweb) never needs access to the certificate private key.
// Non-admin port binding requires two one-time netsh registrations performed by
// Install-OsmUserWeb.ps1:
//   netsh http add urlacl url=https://+:<port>/ user=DOMAIN\svc-osmweb
//   netsh http add sslcert ipport=0.0.0.0:<port> certhash=<thumbprint> appid={guid}
// URL prefixes come from the ASPNETCORE_URLS service registry environment variable.
builder.WebHost.UseHttpSys(options =>
{
    options.Authentication.Schemes = AuthenticationSchemes.None;
    options.Authentication.AllowAnonymous = true;
});

builder.Services.Configure<AdSettings>(builder.Configuration.GetSection("AdSettings"));
builder.Services.AddScoped<AdUserService>();

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
