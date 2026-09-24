using Xunit;

namespace AmlabHello.Tests;

public sealed class AgentAccessTests
{
    [Fact]
    public void HostedIdentityRequiresPlatformAuthenticationAndAnExplicitOperator()
    {
        var principal = Guid.NewGuid().ToString();
        Assert.True(AgentAccess.AllowsHostedIdentity("True", principal, [principal]));
        Assert.True(AgentAccess.AllowsHostedIdentity("true", principal.ToUpperInvariant(), [principal]));
        Assert.False(AgentAccess.AllowsHostedIdentity("False", principal, [principal]));
        Assert.False(AgentAccess.AllowsHostedIdentity(null, principal, [principal]));
        Assert.False(AgentAccess.AllowsHostedIdentity("True", null, [principal]));
        Assert.False(AgentAccess.AllowsHostedIdentity("True", principal, []));
        Assert.False(AgentAccess.AllowsHostedIdentity("True", principal, [Guid.NewGuid().ToString()]));
        Assert.False(AgentAccess.AllowsHostedIdentity("True", "untrusted", ["untrusted"]));
        Assert.False(AgentAccess.AllowsHostedIdentity("True", principal + "," + principal, [principal]));
    }
}