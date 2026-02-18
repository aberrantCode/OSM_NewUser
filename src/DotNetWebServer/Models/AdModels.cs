namespace OsmUserWeb.Models;

public record AdSettings
{
    public string DefaultPassword { get; init; } = string.Empty;
    public string TargetOU       { get; init; } = string.Empty;
    public string GroupName      { get; init; } = string.Empty;
}

public record UserPreview(
    string Username,
    string Upn,
    string TargetOU,
    string GroupName);

public record CreateUserRequest(
    string? BaseName,
    string? Password);

public record CreatedUserDetails(
    string Name,
    string SamAccountName,
    string UserPrincipalName,
    bool   Enabled,
    bool   PasswordNeverExpires,
    bool   UserCannotChangePassword,
    string MemberOf,
    string OU);
