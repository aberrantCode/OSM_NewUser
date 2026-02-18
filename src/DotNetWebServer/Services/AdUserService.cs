using System.DirectoryServices;
using System.DirectoryServices.AccountManagement;
using System.DirectoryServices.ActiveDirectory;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Options;
using OsmUserWeb.Models;

namespace OsmUserWeb.Services;

public partial class AdUserService(IOptions<AdSettings> settings, ILogger<AdUserService> logger)
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

    // ── Private helpers ───────────────────────────────────────────────────────

    private string ResolveBaseName(string? baseName)
    {
        if (!string.IsNullOrWhiteSpace(baseName))
            return baseName.Trim();

        var processUser = Environment.UserName;
        var derived     = TrailingDigitsRegex().Replace(processUser, string.Empty);

        if (string.IsNullOrWhiteSpace(derived))
            throw new ArgumentException(
                "Base name resolved to an empty string. Provide a BaseName explicitly.");

        logger.LogInformation("Derived base name '{Base}' from process user '{User}'", derived, processUser);
        return derived;
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
        var pattern = new Regex(
            $@"^{Regex.Escape(baseName)}(\d+)$",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);

        using var query   = new UserPrincipal(ctx) { SamAccountName = $"{baseName}*" };
        using var searcher = new PrincipalSearcher(query);

        var numbers = new List<int>();
        using var results = searcher.FindAll();
        foreach (var principal in results)
        {
            if (principal is not UserPrincipal up) continue;
            var match = pattern.Match(up.SamAccountName ?? string.Empty);
            if (match.Success)
                numbers.Add(int.Parse(match.Groups[1].Value));
        }

        return (numbers.Count > 0 ? numbers.Max() : 0) + 1;
    }

    private static string GetDomainDnsRoot()
    {
        using var domain = Domain.GetCurrentDomain();
        return domain.Name;
    }

    private static string BuildMemberOf(UserPrincipal user)
    {
        var names = new List<string>();
        foreach (var group in user.GetGroups())
        {
            if (!string.IsNullOrEmpty(group.Name))
                names.Add(group.Name);
        }
        return string.Join(", ", names);
    }

    [GeneratedRegex(@"\d+$")]
    private static partial Regex TrailingDigitsRegex();
}
