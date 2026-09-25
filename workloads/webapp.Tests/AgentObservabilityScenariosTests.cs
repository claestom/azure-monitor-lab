using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.Extensibility;
using Microsoft.AspNetCore.Http;
using Xunit;

namespace AmlabHello.Tests;

public sealed class AgentObservabilityScenariosTests
{
    private sealed class ImmediateDelay : IAgentScenarioDelay
    {
        public List<TimeSpan> Delays { get; } = [];
        public Task WaitAsync(TimeSpan delay, CancellationToken cancellationToken)
        {
            Delays.Add(delay);
            return Task.CompletedTask;
        }
    }

    private static (AgentObservabilityScenarios Service, ImmediateDelay Delay) Create()
    {
        var delay = new ImmediateDelay();
        var telemetry = new TelemetryClient(new TelemetryConfiguration { DisableTelemetry = true });
        return (new AgentObservabilityScenarios(telemetry, delay), delay);
    }

    [Theory]
    [InlineData(null, "broken")]
    [InlineData("unknown", "broken")]
    [InlineData("slow-tool", "unknown")]
    public async Task InvalidScenarioOrModeIsRejected(string? scenario, string mode)
    {
        var (service, _) = Create();
        var result = await service.RunAsync(new(scenario, mode, true), default);
        Assert.Equal(400, Assert.IsAssignableFrom<IStatusCodeHttpResult>(result).StatusCode);
    }

    [Fact]
    public async Task ConsentIsRequired()
    {
        var (service, _) = Create();
        var result = await service.RunAsync(new("slow-tool", "broken", false), default);
        Assert.Equal(400, Assert.IsAssignableFrom<IStatusCodeHttpResult>(result).StatusCode);
    }

    [Fact]
    public async Task SlowToolShowsMeasurableBrokenAndFixedProfiles()
    {
        var (service, delay) = Create();
        var broken = await service.RunAsync(new("slow-tool", "broken", true), default);
        var fixedResult = await service.RunAsync(new("slow-tool", "fixed", true), default);
        Assert.Null(Assert.IsAssignableFrom<IStatusCodeHttpResult>(broken).StatusCode);
        Assert.Null(Assert.IsAssignableFrom<IStatusCodeHttpResult>(fixedResult).StatusCode);
        Assert.Equal(TimeSpan.FromMilliseconds(2500), delay.Delays[0]);
        Assert.Equal(TimeSpan.FromMilliseconds(100), delay.Delays[1]);
    }

    [Fact]
    public async Task WrongToolFailsUntilRoutingIsFixed()
    {
        var (service, _) = Create();
        var broken = await service.RunAsync(new("wrong-tool", "broken", true), default);
        var fixedResult = await service.RunAsync(new("wrong-tool", "fixed", true), default);
        Assert.Equal(409, Assert.IsAssignableFrom<IStatusCodeHttpResult>(broken).StatusCode);
        var answer = Assert.IsType<AgentScenarioResult>(Assert.IsAssignableFrom<IValueHttpResult>(fixedResult).Value);
        Assert.Equal("order_lookup", answer.SelectedTool);
        Assert.Equal("completed", answer.Status);
    }

    [Fact]
    public async Task PartialFailurePreservesTheSuccessfulFirstTool()
    {
        var (service, delay) = Create();
        var result = await service.RunAsync(new("partial-failure", "broken", true), default);
        Assert.Equal(502, Assert.IsAssignableFrom<IStatusCodeHttpResult>(result).StatusCode);
        Assert.Equal(2, delay.Delays.Count);
    }
}
