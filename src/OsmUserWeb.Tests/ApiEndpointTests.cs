using System.Net;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using OsmUserWeb.Models;
using OsmUserWeb.Services;
using Xunit;

namespace OsmUserWeb.Tests;

// ── Test factory ─────────────────────────────────────────────────────────────

/// <summary>
/// Hosts OsmUserWeb in-process using TestServer.
/// Sets Environment = "Testing" so Program.cs skips UseHttpSys (which requires
/// kernel-mode setup unavailable in a test runner), and substitutes a stub
/// IAdUserService so no Active Directory is needed.
/// </summary>
sealed class OsmUserWebFactory : WebApplicationFactory<Program>
{
    /// <summary>Optional override for the AD service stub (default: <see cref="StubAdUserService"/>).</summary>
    public IAdUserService? AdServiceOverride { get; init; }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");

        // Suppress "Now listening on: ..." startup noise in the build log.
        builder.ConfigureLogging(logging =>
            logging.AddFilter("Microsoft.Hosting.Lifetime", LogLevel.Warning));

        builder.ConfigureServices(services =>
        {
            // Remove the real IAdUserService registration and replace with a stub.
            var descriptor = services.SingleOrDefault(
                d => d.ServiceType == typeof(IAdUserService));
            if (descriptor is not null)
                services.Remove(descriptor);

            var stub = AdServiceOverride ?? new StubAdUserService();
            services.AddScoped<IAdUserService>(_ => stub);
        });
    }
}

// ── Stub implementation ───────────────────────────────────────────────────────

sealed class StubAdUserService : IAdUserService
{
    public UserPreview GetPreview(string? baseName)
    {
        var username = $"{baseName ?? "user"}1";
        return new UserPreview(username, $"{username}@test.local",
            "OU=Test,DC=test,DC=local", "TestGroup");
    }

    public CreatedUserDetails CreateUser(string? baseName, string? password)
    {
        var username = $"{baseName ?? "user"}1";
        return new CreatedUserDetails(
            Name:                     username,
            SamAccountName:           username,
            UserPrincipalName:        $"{username}@test.local",
            Enabled:                  true,
            PasswordNeverExpires:     true,
            UserCannotChangePassword: true,
            MemberOf:                 "TestGroup",
            OU:                       "OU=Test,DC=test,DC=local");
    }
}

/// <summary>Stub that always throws <see cref="ArgumentException"/> from GetPreview.</summary>
sealed class ThrowingPreviewStub : IAdUserService
{
    public UserPreview GetPreview(string? baseName) =>
        throw new ArgumentException("Simulated bad base name.");

    public CreatedUserDetails CreateUser(string? baseName, string? password) =>
        throw new InvalidOperationException("Simulated conflict.");
}

// ── Tests ─────────────────────────────────────────────────────────────────────

public class ApiEndpointTests : IDisposable
{
    private readonly OsmUserWebFactory _factory = new();

    public void Dispose() => _factory.Dispose();

    // ── /api/preview ──────────────────────────────────────────────────────────

    [Fact]
    public async Task GetPreview_WithBaseName_Returns200AndUserPreview()
    {
        var client = _factory.CreateClient();

        var response = await client.GetAsync("/api/preview?baseName=testuser");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        var preview = await response.Content.ReadFromJsonAsync<UserPreview>();
        Assert.NotNull(preview);
        Assert.Equal("testuser1",          preview.Username);
        Assert.Equal("testuser1@test.local", preview.Upn);
        Assert.Equal("TestGroup",          preview.GroupName);
    }

    [Fact]
    public async Task GetPreview_NoBaseName_Returns200WithDerivedUsername()
    {
        var client = _factory.CreateClient();

        // Without a baseName the stub falls back to "user" → "user1"
        var response = await client.GetAsync("/api/preview");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        var preview = await response.Content.ReadFromJsonAsync<UserPreview>();
        Assert.NotNull(preview);
        Assert.StartsWith("user", preview.Username);
    }

    [Fact]
    public async Task GetPreview_ServiceThrowsArgumentException_Returns400()
    {
        var throwingFactory = new OsmUserWebFactory
        {
            AdServiceOverride = new ThrowingPreviewStub()
        };

        var client = throwingFactory.CreateClient();
        var response = await client.GetAsync("/api/preview?baseName=bad");

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);

        throwingFactory.Dispose();
    }

    // ── /api/users ────────────────────────────────────────────────────────────

    [Fact]
    public async Task PostUsers_ValidRequest_Returns201AndCreatedUserDetails()
    {
        var client = _factory.CreateClient();

        var request = new CreateUserRequest("alice", "P@ssw0rd!");
        var response = await client.PostAsJsonAsync("/api/users", request);

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);

        var details = await response.Content.ReadFromJsonAsync<CreatedUserDetails>();
        Assert.NotNull(details);
        Assert.Equal("alice1",                details.SamAccountName);
        Assert.Equal("alice1@test.local",     details.UserPrincipalName);
        Assert.True(details.Enabled);

        // Location header should point to the created resource
        Assert.NotNull(response.Headers.Location);
        Assert.Contains("alice1", response.Headers.Location!.ToString());
    }

    [Fact]
    public async Task PostUsers_ServiceThrowsInvalidOperation_Returns409()
    {
        var throwingFactory = new OsmUserWebFactory
        {
            AdServiceOverride = new ThrowingPreviewStub()
        };

        var client = throwingFactory.CreateClient();
        var response = await client.PostAsJsonAsync(
            "/api/users", new CreateUserRequest("alice", "P@ss!"));

        Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);

        throwingFactory.Dispose();
    }
}
