using System.DirectoryServices;
using System.DirectoryServices.AccountManagement;
using System.DirectoryServices.ActiveDirectory;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Options;
using OsmUserWeb.Models;

namespace OsmUserWeb.Services;

public partial class AdUserService(IOptions<AdSettings> settings, ILogger<AdUserService> logger)
    : IAdUserService
{
    private readonly AdSettings _settings = settings.Value;

    // ── Preview ───────────────────────────────────────────────────────────────

    public UserPreview GetPreview(string? baseName)
    {
        var resolvedBase = ResolveBaseName(baseName);
        VerifyOuExists();

        using var ctx    = new PrincipalContext(ContextType.Domain);
        var nextNumber   = FindNextNumber(resolvedBase, ctx);
        var username     = $"{resolvedBase}{nextNumber}";
        var upn          = $"{username}@{GetDomainDnsRoot()}";

        return new UserPreview(username, upn, _settings.TargetOU, _settings.GroupName);
    }

    // ── Create ────────────────────────────────────────────────────────────────

    public CreatedUserDetails CreateUser(string? baseName, string? password)
    {
        var resolvedBase     = ResolveBaseName(baseName);
        var resolvedPassword = string.IsNullOrWhiteSpace(password)
            ? _settings.DefaultPassword
            : password;

        VerifyOuExists();

        using var domainCtx = new PrincipalContext(ContextType.Domain);
        var dnsRoot         = GetDomainDnsRoot();
        var nextNumber      = FindNextNumber(resolvedBase, domainCtx);
        var username        = $"{resolvedBase}{nextNumber}";
        var upn             = $"{username}@{dnsRoot}";

        logger.LogInformation("Creating AD user '{Username}' in OU '{OU}'", username, _settings.TargetOU);

        // Create user in the target OU
        using var ouCtx  = new PrincipalContext(ContextType.Domain, null, _settings.TargetOU);
        using var newUser = new UserPrincipal(ouCtx, username, resolvedPassword, enabled: true)
        {
            GivenName            = username,
            DisplayName          = username,
            UserPrincipalName    = upn,
            PasswordNeverExpires = true,
            UserCannotChangePassword = true,
        };

        try
        {
            newUser.Save();
        }
        catch (PrincipalExistsException)
        {
            throw new InvalidOperationException(
                $"'{username}' already exists — possible race condition. Re-run to get the next number.");
        }

        logger.LogInformation("User '{Username}' created.", username);

        // Add to group — non-fatal if it fails
        try
        {
            using var group = GroupPrincipal.FindByIdentity(domainCtx, _settings.GroupName);
            if (group is not null)
            {
                group.Members.Add(newUser);
                group.Save();
                logger.LogInformation("Added '{Username}' to '{Group}'.", username, _settings.GroupName);
            }
            else
            {
                logger.LogWarning("Group '{Group}' not found; skipping group membership.", _settings.GroupName);
            }
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex,
                "Failed to add '{Username}' to '{Group}'. The user account was still created.",
                username, _settings.GroupName);
        }

        // Read the account back and return verified details
        var created = UserPrincipal.FindByIdentity(domainCtx, username)
            ?? throw new InvalidOperationException("User was created but could not be read back from AD.");

        var memberOf = BuildMemberOf(created);

        return new CreatedUserDetails(
            created.Name                ?? username,
            created.SamAccountName     ?? username,
            created.UserPrincipalName  ?? upn,
            created.Enabled            ?? false,
            created.PasswordNeverExpires,
            created.UserCannotChangePassword,
            memberOf,
            _settings.TargetOU);
    }

    // ── Pure static helpers (testable without AD) ─────────────────────────────

    /// <summary>
    /// Returns <paramref name="baseName"/> trimmed if non-empty; otherwise strips
    /// trailing digits from <paramref name="processUser"/> to derive a base name.
    /// </summary>
    internal static string ResolveBaseName(string? baseName, string processUser)
    {
        if (!string.IsNullOrWhiteSpace(baseName))
            return baseName.Trim();

        var derived = TrailingDigitsRegex().Replace(processUser, string.Empty);

        if (string.IsNullOrWhiteSpace(derived))
            throw new ArgumentException(
                "Base name resolved to an empty string. Provide a BaseName explicitly.");

        return derived;
    }

    /// <summary>
    /// Returns max(suffix numbers among <paramref name="existingNames"/> that match
    /// <c>^{baseName}\d+$</c>) + 1, or 1 when no matches exist.
    /// </summary>
    internal static int ComputeNextNumber(string baseName, IEnumerable<string> existingNames)
    {
        var pattern = new Regex(
            $@"^{Regex.Escape(baseName)}(\d+)$",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);

        var numbers = new List<int>();
        foreach (var name in existingNames)
        {
            var match = pattern.Match(name);
            if (match.Success)
                numbers.Add(int.Parse(match.Groups[1].Value));
        }

        return (numbers.Count > 0 ? numbers.Max() : 0) + 1;
    }

    /// <summary>
    /// Joins non-null, non-empty group names with ", ".
    /// </summary>
    internal static string FormatMemberOf(IEnumerable<string?> groupNames) =>
        string.Join(", ", groupNames.Where(n => !string.IsNullOrEmpty(n)));

    // ── Private instance helpers ──────────────────────────────────────────────

    private string ResolveBaseName(string? baseName)
    {
        var processUser = Environment.UserName;
        var resolved    = ResolveBaseName(baseName, processUser);

        if (string.IsNullOrWhiteSpace(baseName))
            logger.LogInformation("Derived base name '{Base}' from process user '{User}'",
                resolved, processUser);

        return resolved;
    }

    private void VerifyOuExists()
    {
        try
        {
            using var entry = new DirectoryEntry($"LDAP://{_settings.TargetOU}");
            entry.RefreshCache(); // throws DirectoryServicesCOMException if the OU is absent
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException($"Target OU not found: {_settings.TargetOU}", ex);
        }
    }

    private static int FindNextNumber(string baseName, PrincipalContext ctx)
    {
        using var query    = new UserPrincipal(ctx) { SamAccountName = $"{baseName}*" };
        using var searcher = new PrincipalSearcher(query);

        var names = new List<string>();
        using var results = searcher.FindAll();
        foreach (var principal in results)
        {
            if (principal is UserPrincipal up)
                names.Add(up.SamAccountName ?? string.Empty);
        }

        return ComputeNextNumber(baseName, names);
    }

    private static string GetDomainDnsRoot()
    {
        using var domain = Domain.GetCurrentDomain();
        return domain.Name;
    }

    private static string BuildMemberOf(UserPrincipal user) =>
        FormatMemberOf(user.GetGroups().Select(g => g.Name));

    [GeneratedRegex(@"\d+$")]
    private static partial Regex TrailingDigitsRegex();
}
