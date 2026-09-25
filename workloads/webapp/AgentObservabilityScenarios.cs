using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.DataContracts;
using System.Diagnostics;

public sealed record AgentScenarioRequest(string? Scenario, string? Mode, bool Consent);
public sealed record AgentScenarioEntry(string Key, string Name, string Description);
public sealed record AgentScenarioResult(string Scenario, string Mode, string Status, string SelectedTool,
    string ExpectedTool, double DurationMs, string? TraceId);

public interface IAgentScenarioDelay
{
    Task WaitAsync(TimeSpan delay, CancellationToken cancellationToken);
}

public sealed class AgentScenarioDelay : IAgentScenarioDelay
{
    public Task WaitAsync(TimeSpan delay, CancellationToken cancellationToken) => Task.Delay(delay, cancellationToken);
}

public sealed class AgentObservabilityScenarios(TelemetryClient telemetry, IAgentScenarioDelay delay)
{
    public static readonly IReadOnlyList<AgentScenarioEntry> Catalog =
    [
        new("slow-tool", "Slow customer lookup", "A downstream customer lookup dominates the agent response time."),
        new("wrong-tool", "Wrong tool selection", "Ambiguous routing sends an order question to the inventory tool."),
        new("partial-failure", "Partial task failure", "The customer lookup succeeds before the order tool fails.")
    ];

    private static readonly HashSet<string> Modes = new(StringComparer.Ordinal) { "broken", "fixed" };

    public async Task<IResult> RunAsync(AgentScenarioRequest request, CancellationToken cancellationToken)
    {
        var scenario = request.Scenario?.Trim().ToLowerInvariant();
        var mode = request.Mode?.Trim().ToLowerInvariant();
        if (scenario is null || !Catalog.Any(entry => entry.Key == scenario))
            return Results.BadRequest(new { error = "Choose a supported observability scenario." });
        if (mode is null || !Modes.Contains(mode))
            return Results.BadRequest(new { error = "Mode must be broken or fixed." });
        if (!request.Consent)
            return Results.BadRequest(new { error = "Confirm that this request generates demo telemetry." });

        var started = Stopwatch.StartNew();
        var expectedTool = scenario == "slow-tool" ? "customer_lookup" : "order_lookup";
        var selectedTool = scenario == "wrong-tool" && mode == "broken" ? "inventory_lookup" : expectedTool;
        var status = "completed";
        var resultCode = "200";
        var success = true;

        try
        {
            if (scenario == "partial-failure")
            {
                await TrackToolAsync("customer_lookup", TimeSpan.FromMilliseconds(100), true, "200",
                    scenario, mode, expectedTool, cancellationToken);
                if (mode == "broken")
                {
                    await TrackToolAsync("order_lookup", TimeSpan.FromMilliseconds(250), false, "503",
                        scenario, mode, expectedTool, cancellationToken);
                    status = "partial_failure";
                    resultCode = "502";
                    success = false;
                }
                else
                {
                    await TrackToolAsync("order_lookup", TimeSpan.FromMilliseconds(100), true, "200",
                        scenario, mode, expectedTool, cancellationToken);
                }
            }
            else
            {
                var duration = scenario == "slow-tool" && mode == "broken"
                    ? TimeSpan.FromMilliseconds(2500)
                    : TimeSpan.FromMilliseconds(100);
                var correct = selectedTool == expectedTool;
                await TrackToolAsync(selectedTool, duration, correct, correct ? "200" : "409",
                    scenario, mode, expectedTool, cancellationToken);
                if (!correct)
                {
                    status = "wrong_tool";
                    resultCode = "409";
                    success = false;
                }
            }

            var properties = Dimensions(scenario, mode, selectedTool, expectedTool);
            properties["outcome"] = status;
            properties["tool.selection.correct"] = (selectedTool == expectedTool).ToString().ToLowerInvariant();
            telemetry.TrackEvent("AgentObservabilityScenarioCompleted", properties,
                new Dictionary<string, double> { ["duration_ms"] = started.Elapsed.TotalMilliseconds });
        }
        catch (OperationCanceledException)
        {
            status = "cancelled";
            resultCode = "499";
            success = false;
            throw;
        }
        finally
        {
            var dependency = new DependencyTelemetry
            {
                Type = "GenAI",
                Name = "customer_support_agent",
                Target = "obs-agent-demo",
                Timestamp = DateTimeOffset.UtcNow - started.Elapsed,
                Duration = started.Elapsed,
                Success = success,
                ResultCode = resultCode
            };
            foreach (var dimension in Dimensions(scenario, mode, selectedTool, expectedTool))
                dependency.Properties[dimension.Key] = dimension.Value;
            dependency.Properties["outcome"] = status;
            telemetry.TrackDependency(dependency);
        }

        var response = new AgentScenarioResult(scenario, mode, status, selectedTool, expectedTool,
            started.Elapsed.TotalMilliseconds, Activity.Current?.TraceId.ToString());
        return success
            ? Results.Json(response)
            : Results.Json(response, statusCode: scenario == "wrong-tool" ? 409 : 502);
    }

    private async Task TrackToolAsync(string tool, TimeSpan duration, bool success, string resultCode,
        string scenario, string mode, string expectedTool, CancellationToken cancellationToken)
    {
        var started = DateTimeOffset.UtcNow;
        await delay.WaitAsync(duration, cancellationToken);
        var dependency = new DependencyTelemetry
        {
            Type = "AgentTool",
            Name = tool,
            Target = "lab-tool-simulator",
            Timestamp = started,
            Duration = duration,
            Success = success,
            ResultCode = resultCode
        };
        foreach (var dimension in Dimensions(scenario, mode, tool, expectedTool))
            dependency.Properties[dimension.Key] = dimension.Value;
        dependency.Properties["tool.selection.correct"] = (tool == expectedTool).ToString().ToLowerInvariant();
        telemetry.TrackDependency(dependency);
    }

    private static Dictionary<string, string> Dimensions(string scenario, string mode, string selectedTool, string expectedTool) => new()
    {
        ["gen_ai.agent.name"] = "Customer Support Agent",
        ["gen_ai.operation.name"] = "execute_tool",
        ["gen_ai.tool.name"] = selectedTool,
        ["scenario"] = scenario,
        ["demo.mode"] = mode,
        ["expected_tool"] = expectedTool,
        ["source"] = "obs-agent-demo",
        ["content_recording.enabled"] = "false"
    };
}
