using Xunit;

namespace AmlabHello.Tests;

public sealed class LabOperationCatalogTests
{
    [Fact]
    public void OnlyTheSixApprovedScriptsAreAvailable()
    {
        Assert.Equal(new[] { "start", "break", "restore", "ramp", "logs", "annotation" }, LabOperationCatalog.Actions.Select(action => action.Id));
        Assert.All(LabOperationCatalog.Actions, action => Assert.StartsWith("scripts/", action.Script));
        Assert.All(LabOperationCatalog.Actions, action => Assert.NotEmpty(action.Impact));
        foreach (var operation in new[] { "teardown", "deploy", "setup-rbac-demo", "../script.ps1", "start;whoami" })
            Assert.Throws<ArgumentException>(() => LabOperationCatalog.Validate(new(operation)));
    }

    [Theory]
    [InlineData("start")]
    [InlineData("break")]
    [InlineData("restore")]
    [InlineData("ramp")]
    public void LifecycleActionsRejectExtraParameters(string operation)
    {
        Assert.Equal(new(operation, 0, "", ""), LabOperationCatalog.Validate(new(operation)));
        Assert.Throws<ArgumentException>(() => LabOperationCatalog.Validate(new(operation, Count: 1)));
        Assert.Throws<ArgumentException>(() => LabOperationCatalog.Validate(new(operation, Name: "marker")));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    [InlineData(101)]
    public void CustomLogCountIsBounded(int count) => Assert.Throws<ArgumentException>(() => LabOperationCatalog.Validate(new("logs", Count: count)));

    [Fact]
    public void ValidParametersAreNormalized()
    {
        Assert.Equal(10, LabOperationCatalog.Validate(new("logs")).Count);
        Assert.Equal(100, LabOperationCatalog.Validate(new("logs", Count: 100)).Count);
        Assert.Equal(new("annotation", 0, "Release 1.2 (demo)", "Deployment"), LabOperationCatalog.Validate(new("annotation", Name: " Release 1.2 (demo) ")));
        Assert.Equal("Incident", LabOperationCatalog.Validate(new("annotation", Name: "Lab break", Category: "Incident")).Category);
    }

    [Theory]
    [InlineData("")]
    [InlineData("hello\nworld")]
    [InlineData("$(whoami)")]
    [InlineData("a; az group delete")]
    public void AnnotationRejectsUnsafeNames(string name) => Assert.Throws<ArgumentException>(() => LabOperationCatalog.Validate(new("annotation", Name: name)));

    [Fact]
    public void AnnotationRejectsLongNamesAndUnknownCategories()
    {
        Assert.Throws<ArgumentException>(() => LabOperationCatalog.Validate(new("annotation", Name: new string('a', 81))));
        Assert.Throws<ArgumentException>(() => LabOperationCatalog.Validate(new("annotation", Name: "marker", Category: "arbitrary")));
    }
}