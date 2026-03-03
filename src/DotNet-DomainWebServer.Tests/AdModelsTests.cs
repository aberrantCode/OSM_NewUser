using OsmUserWeb.Models;
using Xunit;

namespace OsmUserWeb.Tests;

public class AdSettingsTests
{
    [Fact]
    public void AdSettings_DefaultValues_AreEmptyStrings()
    {
        var settings = new AdSettings();

        Assert.Equal(string.Empty, settings.DefaultPassword);
        Assert.Equal(string.Empty, settings.TargetOU);
        Assert.Equal(string.Empty, settings.GroupName);
    }

    [Fact]
    public void AdSettings_InitProperties_RoundTrip()
    {
        var settings = new AdSettings
        {
            DefaultPassword = "P@ssw0rd!",
            TargetOU        = "OU=Users,DC=example,DC=com",
            GroupName       = "OsmUsers"
        };

        Assert.Equal("P@ssw0rd!",                   settings.DefaultPassword);
        Assert.Equal("OU=Users,DC=example,DC=com",  settings.TargetOU);
        Assert.Equal("OsmUsers",                    settings.GroupName);
    }

    [Fact]
    public void AdSettings_EqualityByValue()
    {
        var a = new AdSettings { DefaultPassword = "x", TargetOU = "ou", GroupName = "g" };
        var b = new AdSettings { DefaultPassword = "x", TargetOU = "ou", GroupName = "g" };

        Assert.Equal(a, b);
    }

    [Fact]
    public void AdSettings_InequalityOnDifferentField()
    {
        var a = new AdSettings { DefaultPassword = "x", TargetOU = "ou", GroupName = "g" };
        var b = new AdSettings { DefaultPassword = "y", TargetOU = "ou", GroupName = "g" };

        Assert.NotEqual(a, b);
    }
}

public class UserPreviewTests
{
    [Fact]
    public void UserPreview_ConstructorParams_SetProperties()
    {
        var preview = new UserPreview("jdoe", "jdoe@example.com", "OU=Users,DC=example,DC=com", "OsmUsers");

        Assert.Equal("jdoe",                         preview.Username);
        Assert.Equal("jdoe@example.com",             preview.Upn);
        Assert.Equal("OU=Users,DC=example,DC=com",   preview.TargetOU);
        Assert.Equal("OsmUsers",                     preview.GroupName);
    }

    [Fact]
    public void UserPreview_EqualityByValue()
    {
        var a = new UserPreview("u", "u@x.com", "ou", "g");
        var b = new UserPreview("u", "u@x.com", "ou", "g");

        Assert.Equal(a, b);
    }
}

public class CreateUserRequestTests
{
    [Fact]
    public void CreateUserRequest_NullableFields_AcceptNull()
    {
        var req = new CreateUserRequest(null, null);

        Assert.Null(req.BaseName);
        Assert.Null(req.Password);
    }

    [Fact]
    public void CreateUserRequest_WithValues_RoundTrip()
    {
        var req = new CreateUserRequest("john", "Secret1!");

        Assert.Equal("john",    req.BaseName);
        Assert.Equal("Secret1!", req.Password);
    }
}

public class CreatedUserDetailsTests
{
    [Fact]
    public void CreatedUserDetails_ConstructorParams_SetProperties()
    {
        var details = new CreatedUserDetails(
            Name:                   "John Doe",
            SamAccountName:         "jdoe",
            UserPrincipalName:      "jdoe@example.com",
            Enabled:                true,
            PasswordNeverExpires:   false,
            UserCannotChangePassword: false,
            MemberOf:               "OsmUsers",
            OU:                     "OU=Users,DC=example,DC=com");

        Assert.Equal("John Doe",                    details.Name);
        Assert.Equal("jdoe",                        details.SamAccountName);
        Assert.Equal("jdoe@example.com",            details.UserPrincipalName);
        Assert.True(details.Enabled);
        Assert.False(details.PasswordNeverExpires);
        Assert.False(details.UserCannotChangePassword);
        Assert.Equal("OsmUsers",                    details.MemberOf);
        Assert.Equal("OU=Users,DC=example,DC=com",  details.OU);
    }

    [Fact]
    public void CreatedUserDetails_EqualityByValue()
    {
        var a = new CreatedUserDetails("N", "s", "u", true, false, false, "g", "ou");
        var b = new CreatedUserDetails("N", "s", "u", true, false, false, "g", "ou");

        Assert.Equal(a, b);
    }
}
