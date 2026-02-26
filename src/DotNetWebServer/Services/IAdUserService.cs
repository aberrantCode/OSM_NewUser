using OsmUserWeb.Models;

namespace OsmUserWeb.Services;

public interface IAdUserService
{
    UserPreview GetPreview(string? baseName);
    CreatedUserDetails CreateUser(string? baseName, string? password);
}
