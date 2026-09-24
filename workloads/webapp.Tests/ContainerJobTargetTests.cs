using Microsoft.Extensions.Configuration;
using Xunit;

namespace AmlabHello.Tests;

public sealed class ContainerJobTargetTests
{
    private static IConfiguration Settings(Action<Dictionary<string, string?>>? change = null)
    {
        var values = new Dictionary<string, string?>
        {
            ["LabConsole:ResourceGroup"] = "test-rg", ["LabConsole:Operations:TenantId"] = Guid.NewGuid().ToString(),
            ["LabConsole:Operations:JobResourceId"] = $"/subscriptions/{Guid.NewGuid()}/resourceGroups/test-rg/providers/Microsoft.App/jobs/lab-operations",
            ["LabConsole:Operations:Image"] = "test.azurecr.io/lab-operations@sha256:" + new string('a', 64)
        };
        change?.Invoke(values);
        return new ConfigurationBuilder().AddInMemoryCollection(values).Build();
    }

    [Fact]
    public void AcceptsAnInScopeJobWithAnImmutableImage()
    {
        var target = ContainerJobTarget.FromConfiguration(Settings());
        Assert.NotNull(target);
        Assert.Equal("test-rg", target.ResourceGroup);
        Assert.Contains("@sha256:", target.Image);
        Assert.Contains("/providers/Microsoft.App/jobs/", target.JobResourceId);
    }

    [Theory]
    [InlineData("LabConsole:Operations:Image", "test.azurecr.io/lab-operations:latest")]
    [InlineData("LabConsole:Operations:Image", "https://attacker.example/script")]
    [InlineData("LabConsole:Operations:TenantId", "invalid")]
    [InlineData("LabConsole:ResourceGroup", "other-rg")]
    [InlineData("LabConsole:Operations:JobResourceId", "https://management.azure.com/jobs/test")]
    public void InvalidScopeAndMutableImagesAreRejected(string setting, string value)
    {
        Assert.Null(ContainerJobTarget.FromConfiguration(Settings(values => values[setting] = value)));
    }

    [Fact]
    public void NestedJobsAndAlternativeResourceTypesAreRejected()
    {
        Assert.Null(ContainerJobTarget.FromConfiguration(Settings(values => values["LabConsole:Operations:JobResourceId"] += "/executions/test")));
        Assert.Null(ContainerJobTarget.FromConfiguration(Settings(values => values["LabConsole:Operations:JobResourceId"] = values["LabConsole:Operations:JobResourceId"]!.Replace("Microsoft.App/jobs", "Microsoft.Web/sites"))));
    }
}