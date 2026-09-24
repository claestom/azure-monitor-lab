public static class AgentAccess
{
    public static bool AllowsHostedIdentity(string? authenticationEnabled, string? principalId, IEnumerable<string> allowedPrincipalIds) =>
        string.Equals(authenticationEnabled, "True", StringComparison.OrdinalIgnoreCase)
        && Guid.TryParse(principalId, out var principal)
        && allowedPrincipalIds.Any(value => Guid.TryParse(value, out var allowed) && allowed == principal);
}