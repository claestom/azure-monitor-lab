using System.Text.Json;
using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.Extensibility;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Time.Testing;
using OpenAI.Chat;
using Xunit;

namespace AmlabHello.Tests;

public sealed class SreAssistantTests
{
    private static IConfiguration Settings(bool enabled = true) => new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
    {
        ["LabConsole:Sre:Enabled"] = enabled.ToString(), ["LabConsole:Sre:SubscriptionId"] = "11111111-1111-1111-1111-111111111111",
        ["LabConsole:Sre:TenantId"] = "22222222-2222-2222-2222-222222222222", ["LabConsole:ResourceGroup"] = "test-rg",
        ["LabConsole:Sre:AgentName"] = "test-agent", ["LabConsole:Sre:McpExecutable"] = "test-only"
    }).Build();
    private static SreAssistant Create(FakeMcp mcp, FakeModel model, bool enabled = true, TimeProvider? clock = null) => new(Settings(enabled), mcp, model,
        NullLogger<SreAssistant>.Instance, new TelemetryClient(new TelemetryConfiguration { DisableTelemetry = true }), clock);
    private static SreAssistantRequest Question(string? sessionId = null) => new(sessionId, "List the agents", true);
    private static SreAssistantReply Reply(IResult result) => Assert.IsType<SreAssistantReply>(Assert.IsAssignableFrom<IValueHttpResult>(result).Value);
    private static JsonElement ResultJson(IResult result) => JsonSerializer.SerializeToElement(Assert.IsAssignableFrom<IValueHttpResult>(result).Value);
    private static int? Status(IResult result) => Assert.IsAssignableFrom<IStatusCodeHttpResult>(result).StatusCode;
    private static SreModelStep Tool(string name, string arguments = "{}") => new("", ChatToolCall.CreateFunctionToolCall(Guid.NewGuid().ToString("N"), name, BinaryData.FromString(arguments)), 100, 20);

    [Fact]
    public async Task AvailabilityAllowsSlowStartupWithoutCallingModelOrTools()
    {
        var clock = new FakeTimeProvider();
        var mcp = new FakeMcp { BlockCatalog = true };
        var model = new FakeModel();
        var service = Create(mcp, model, clock: clock);
        var running = service.AvailabilityAsync(default);
        try
        {
            clock.Advance(TimeSpan.FromSeconds(30));
            Assert.False(mcp.CatalogCancellation.IsCancellationRequested);
            Assert.False(running.IsCompleted);
        }
        finally { mcp.CatalogReady.TrySetResult(); }
        var result = ResultJson(await running);
        Assert.True(result.GetProperty("available").GetBoolean());
        Assert.True(ResultJson(await service.AvailabilityAsync(default)).GetProperty("available").GetBoolean());
        Assert.Equal(1, mcp.CatalogCalls);
        Assert.Empty(model.Tools);
        Assert.Empty(mcp.Calls);
    }

    [Fact]
    public async Task AvailabilityTimeoutIsBoundedAndAllowsAnotherConnectionCheck()
    {
        var clock = new FakeTimeProvider();
        var mcp = new FakeMcp { BlockCatalog = true };
        var model = new FakeModel();
        var service = Create(mcp, model, clock: clock);
        var running = service.AvailabilityAsync(default);
        clock.Advance(TimeSpan.FromSeconds(89));
        Assert.False(mcp.CatalogCancellation.IsCancellationRequested);
        clock.Advance(TimeSpan.FromSeconds(1));
        var result = await running.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(504, Status(result));
        Assert.Equal("startup_timeout", ResultJson(result).GetProperty("state").GetString());
        Assert.False(ResultJson(result).GetProperty("available").GetBoolean());
        mcp.BlockCatalog = false;
        Assert.True(ResultJson(await service.AvailabilityAsync(default)).GetProperty("available").GetBoolean());
        Assert.Equal(2, mcp.CatalogCalls);
        Assert.Empty(model.Tools);
        Assert.Empty(mcp.Calls);
    }

    [Fact]
    public async Task AvailabilityCallerCancellationReleasesLockWithoutExecutingTools()
    {
        var mcp = new FakeMcp { BlockCatalog = true };
        var model = new FakeModel();
        var service = Create(mcp, model, clock: new FakeTimeProvider());
        using var cancellation = new CancellationTokenSource();
        var running = service.AvailabilityAsync(cancellation.Token);
        Assert.False(ResultJson(await service.AvailabilityAsync(default)).GetProperty("available").GetBoolean());
        Assert.Equal(1, mcp.CatalogCalls);
        cancellation.Cancel();
        Assert.False(ResultJson(await running.WaitAsync(TimeSpan.FromSeconds(5))).GetProperty("available").GetBoolean());
        mcp.BlockCatalog = false;
        Assert.True(ResultJson(await service.AvailabilityAsync(default)).GetProperty("available").GetBoolean());
        Assert.Empty(model.Tools);
        Assert.Empty(mcp.Calls);
    }

    [Fact]
    public async Task QuestionUsesDirectScopedManagementToolAndNeverCreatesThread()
    {
        var mcp = new FakeMcp();
        var model = new FakeModel(Tool("sreagent_agents_list"), new("One SRE agent exists.", null, 200, 30));
        var reply = Reply(await Create(mcp, model).AskAsync("alice", Question(), default));
        Assert.Equal("ready", reply.State);
        Assert.Null(reply.Proposal);
        Assert.Equal("One SRE agent exists.", reply.Messages.Last().Text);
        var call = Assert.Single(mcp.Calls);
        Assert.Equal("sreagent_agents_list", call.Tool);
        Assert.Equal("11111111-1111-1111-1111-111111111111", call.Arguments["subscription"].GetString());
        Assert.Equal("test-rg", call.Arguments["resource-group"].GetString());
        Assert.DoesNotContain("agent", call.Arguments.Keys);
        Assert.DoesNotContain(model.Tools[0], tool => tool.Name.Contains("threads"));
        Assert.False(model.Tools[0][0].InputSchema.GetProperty("properties").TryGetProperty("subscription", out _));
        Assert.Equal(300, reply.InputTokens);
        Assert.Equal(50, reply.OutputTokens);
        Assert.Contains(model.Histories[1], message => message is ToolChatMessage);
    }

    [Fact]
    public async Task WriteProposalIsBoundToUserFrozenAndExecutedOnlyOnce()
    {
        var mcp = new FakeMcp();
        var model = new FakeModel(Tool("sreagent_scheduledtasks_pause", "{\"task-id\":\"nightly\"}"));
        var service = Create(mcp, model);
        var reply = Reply(await service.AskAsync("alice", Question(), default));
        Assert.Equal("approval_required", reply.State);
        Assert.Empty(mcp.Calls);
        Assert.Equal("nightly", reply.Proposal!.Arguments.GetProperty("task-id").GetString());
        Assert.Equal("test-agent", reply.Proposal.Arguments.GetProperty("agent").GetString());
        Assert.Equal(404, Status(await service.ResolveAsync("bob", new(reply.SessionId, reply.Proposal.Id, true), default)));
        Assert.Equal(404, Status(await service.ReadAsync("bob", reply.SessionId, default)));
        Assert.Equal(409, Status(await service.AskAsync("alice", Question(reply.SessionId), default)));
        var completed = Reply(await service.ResolveAsync("alice", new(reply.SessionId, reply.Proposal.Id, true), default));
        Assert.Equal("ready", completed.State);
        Assert.Equal("succeeded", Assert.Single(completed.Operations).Status);
        Assert.Equal("nightly", Assert.Single(mcp.Calls).Arguments["task-id"].GetString());
        Assert.Equal(409, Status(await service.ResolveAsync("alice", new(reply.SessionId, reply.Proposal.Id, true), default)));
        Assert.Single(mcp.Calls);
        Assert.Single(model.Tools);
    }

    [Fact]
    public async Task DeclinedWriteDoesNotCallMcp()
    {
        var mcp = new FakeMcp();
        var service = Create(mcp, new FakeModel(Tool("sreagent_scheduledtasks_pause", "{\"task-id\":\"nightly\"}")));
        var reply = Reply(await service.AskAsync("alice", Question(), default));
        var declined = Reply(await service.ResolveAsync("alice", new(reply.SessionId, reply.Proposal!.Id, false), default));
        Assert.Null(declined.Proposal);
        Assert.Equal("ready", declined.State);
        Assert.Empty(mcp.Calls);
    }

    [Fact]
    public async Task FailedWriteHasUnknownOutcomeAndCannotBeReplayedOrAutomaticallyRetried()
    {
        var mcp = new FakeMcp { Fail = true };
        var service = Create(mcp, new FakeModel(Tool("sreagent_scheduledtasks_pause", "{\"task-id\":\"nightly\"}")));
        var reply = Reply(await service.AskAsync("alice", Question(), default));
        var result = await service.ResolveAsync("alice", new(reply.SessionId, reply.Proposal!.Id, true), default);
        Assert.Equal(502, Status(result));
        Assert.Equal("unknown", Reply(result).State);
        Assert.DoesNotContain("secret-upstream", Reply(result).Error);
        Assert.Equal(409, Status(await service.ResolveAsync("alice", new(reply.SessionId, reply.Proposal.Id, true), default)));
        Assert.Equal(409, Status(await service.AskAsync("alice", Question(reply.SessionId), default)));
        Assert.Single(mcp.Calls);
    }

    [Theory]
    [InlineData("sreagent_threads_create", "{}")]
    [InlineData("sreagent_threads_investigate_yolo", "{}")]
    [InlineData("sreagent_hooks_thread_deactivate", "{}")]
    [InlineData("sreagent_agents_list", "{\"subscription\":\"other\"}")]
    [InlineData("sreagent_agents_list", "{\"unexpected\":true}")]
    [InlineData("sreagent_scheduledtasks_pause", "{\"task-id\":123}")]
    [InlineData("sreagent_scheduledtasks_pause", "{}")]
    public async Task UnsupportedToolsScopeOverridesAndInvalidSchemasNeverExecute(string name, string arguments)
    {
        var mcp = new FakeMcp();
        var result = await Create(mcp, new FakeModel(Tool(name, arguments))).AskAsync("alice", Question(), default);
        Assert.Equal(502, Status(result));
        Assert.Null(Reply(result).Proposal);
        Assert.Empty(mcp.Calls);
    }

    [Fact]
    public async Task ReadLoopIsBoundedAndFinalAnswerCannotCallTools()
    {
        var mcp = new FakeMcp();
        var model = new FakeModel(Tool("sreagent_agents_list"), Tool("sreagent_agents_list"), Tool("sreagent_agents_list"), new("Read limit summary.", null, 20, 10));
        var reply = Reply(await Create(mcp, model).AskAsync("alice", Question(), default));
        Assert.Equal(3, mcp.Calls.Count);
        Assert.Empty(model.Tools.Last());
        Assert.Equal("Read limit summary.", reply.Messages.Last().Text);
    }

    [Fact]
    public async Task DisabledAndInvalidRequestsNeverReachModelOrMcp()
    {
        var mcp = new FakeMcp();
        var model = new FakeModel();
        Assert.Equal(503, Status(await Create(mcp, model, false).AskAsync("alice", Question(), default)));
        var service = Create(mcp, model);
        foreach (var request in new[] { Question() with { Prompt = "" }, Question() with { Prompt = new string('a', 4001) }, Question() with { Consent = false } })
            Assert.Equal(400, Status(await service.AskAsync("alice", request, default)));
        Assert.Equal(401, Status(await service.AskAsync("", Question(), default)));
        Assert.Empty(model.Tools);
        Assert.Empty(mcp.Calls);
    }

    [Fact]
    public async Task CancelledReadCannotWriteOrBlockFutureQuestions()
    {
        var mcp = new FakeMcp { Block = true };
        var service = Create(mcp, new FakeModel(Tool("sreagent_agents_list")));
        using var cancel = new CancellationTokenSource();
        var running = service.AskAsync("alice", Question(), cancel.Token);
        await mcp.Started.Task;
        Assert.Equal(429, Status(await service.AskAsync("bob", Question(), default)));
        cancel.Cancel();
        var result = await running;
        Assert.Equal(504, Status(result));
        Assert.Equal("ready", Reply(result).State);
        Assert.All(mcp.Calls, call => Assert.True(SreMcpClient.ReadTools.Contains(call.Tool)));
    }

    [Fact]
    public async Task NativeAdapterRejectsAllInvestigationToolsBeforeConnecting()
    {
        await using var adapter = new SreMcpClient(Settings());
        Assert.DoesNotContain(SreMcpClient.AllowedTools, tool => tool.Contains("threads", StringComparison.Ordinal));
        await Assert.ThrowsAsync<InvalidOperationException>(() => adapter.CallAsync("sreagent_threads_create", new Dictionary<string, object?>(), default));
        Assert.Contains("sreagent_connectors_create_kusto", SreMcpClient.WriteTools);
        Assert.Contains("sreagent_docs_memories_search", SreMcpClient.ReadTools);
    }

    private sealed class FakeModel(params SreModelStep[] steps) : ISreModel
    {
        private readonly Queue<SreModelStep> responses = new(steps);
        public bool Configured => true;
        public string Deployment => "test-model";
        public List<IReadOnlyList<SreTool>> Tools { get; } = [];
        public List<ChatMessage[]> Histories { get; } = [];
        public Task<SreModelStep> CompleteAsync(IReadOnlyList<ChatMessage> messages, IReadOnlyList<SreTool> tools, CancellationToken cancellationToken)
        {
            Tools.Add(tools);
            Histories.Add(messages.ToArray());
            return Task.FromResult(responses.Dequeue());
        }
    }

    private sealed class FakeMcp : ISreMcpClient
    {
        public bool Fail { get; set; }
        public bool Block { get; set; }
        public bool BlockCatalog { get; set; }
        public int CatalogCalls { get; private set; }
        public CancellationToken CatalogCancellation { get; private set; }
        public TaskCompletionSource CatalogReady { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public List<(string Tool, Dictionary<string, JsonElement> Arguments)> Calls { get; } = [];
        public Task<IReadOnlyList<string>> ToolsAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>(SreMcpClient.AllowedTools);
        public async Task<IReadOnlyList<SreTool>> CatalogAsync(CancellationToken cancellationToken)
        {
            CatalogCalls++;
            CatalogCancellation = cancellationToken;
            if (BlockCatalog) await CatalogReady.Task.WaitAsync(cancellationToken);
            return [
                new("sreagent_agents_list", "List SRE resources", JsonDocument.Parse("""{"type":"object","properties":{"subscription":{"type":"string"},"tenant":{"type":"string"},"resource-group":{"type":"string"}}} """).RootElement.Clone(), true),
                new("sreagent_scheduledtasks_pause", "Pause a scheduled task", JsonDocument.Parse("""{"type":"object","properties":{"subscription":{"type":"string"},"tenant":{"type":"string"},"resource-group":{"type":"string"},"agent":{"type":"string"},"task-id":{"type":"string"}},"required":["task-id","agent"]} """).RootElement.Clone(), false)
            ];
        }
        public async Task<JsonElement> CallAsync(string tool, IReadOnlyDictionary<string, object?> arguments, CancellationToken cancellationToken)
        {
            Calls.Add((tool, arguments.ToDictionary(pair => pair.Key, pair => JsonSerializer.SerializeToElement(pair.Value))));
            Started.TrySetResult();
            if (Block) await Task.Delay(Timeout.Infinite, cancellationToken);
            if (Fail) throw new InvalidOperationException("secret-upstream");
            return JsonSerializer.SerializeToElement(new { status = 200, results = new { name = "test-agent" } });
        }
    }
}