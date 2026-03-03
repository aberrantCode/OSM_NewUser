using Microsoft.Extensions.Configuration;
using OsmUserWeb.Models;
using Xunit;

namespace OsmUserWeb.Tests;

/// <summary>
/// Verifies that AdSettings binds correctly from IConfiguration,
/// matching the key structure used in appsettings.json / appsettings.Production.json.
/// </summary>
public class ConfigurationBindingTests
{
    private static IConfiguration BuildConfig(Dictionary<string, string?> values) =>
        new ConfigurationBuilder()
            .AddInMemoryCollection(values)
            .Build();

    [Fact]
    public void AdSettings_BindsFromConfiguration_AllFields()
    {
        var config = BuildConfig(new()
        {
            ["AdSettings:DefaultPassword"] = "P@ss1!",
            ["AdSettings:TargetOU"]        = "OU=Staff,DC=corp,DC=local",
            ["AdSettings:GroupName"]       = "NewUsers"
        });

        var settings = new AdSettings();
        config.GetSection("AdSettings").Bind(settings);

        Assert.Equal("P@ss1!",                  settings.DefaultPassword);
        Assert.Equal("OU=Staff,DC=corp,DC=local", settings.TargetOU);
        Assert.Equal("NewUsers",                settings.GroupName);
    }

    [Fact]
    public void AdSettings_MissingKeys_FallBackToEmptyString()
    {
        var config = BuildConfig(new());

        var settings = new AdSettings();
        config.GetSection("AdSettings").Bind(settings);

        Assert.Equal(string.Empty, settings.DefaultPassword);
        Assert.Equal(string.Empty, settings.TargetOU);
        Assert.Equal(string.Empty, settings.GroupName);
    }

    [Fact]
    public void AdSettings_PartialConfig_BindsAvailableFields()
    {
        var config = BuildConfig(new()
        {
            ["AdSettings:GroupName"] = "Contractors"
        });

        var settings = new AdSettings();
        config.GetSection("AdSettings").Bind(settings);

        Assert.Equal(string.Empty,   settings.DefaultPassword);
        Assert.Equal(string.Empty,   settings.TargetOU);
        Assert.Equal("Contractors",  settings.GroupName);
    }
}
