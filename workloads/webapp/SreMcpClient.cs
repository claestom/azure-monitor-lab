using System.Text.Json;
using ModelContextProtocol.Client;
using ModelContextProtocol.Protocol;

public sealed record SreTool(string Name, string Description, JsonElement InputSchema, bool ReadOnly);

public interface ISreMcpClient
{
    Task<IReadOnlyList<string>> ToolsAsync(CancellationToken cancellationToken);
    Task<IReadOnlyList<SreTool>> CatalogAsync(CancellationToken cancellationToken);
    Task<JsonElement> CallAsync(string tool, IReadOnlyDictionary<string, object?> arguments, CancellationToken cancellationToken);
}

public sealed class SreMcpClient(IConfiguration configuration) : ISreMcpClient, IAsyncDisposable
{
    public static readonly IReadOnlySet<string> ReadTools = new HashSet<string>(StringComparer.Ordinal)
    {
        "sreagent_agents_list", "sreagent_agents_get", "sreagent_agents_tools_list", "sreagent_agents_tools_get",
        "sreagent_connectors_list", "sreagent_connectors_get", "sreagent_skills_list", "sreagent_hooks_list", "sreagent_hooks_get",
        "sreagent_scheduledtasks_list", "sreagent_scheduledtasks_get", "sreagent_incidents_active_list", "sreagent_incidents_plans_list",
        "sreagent_docs_get", "sreagent_docs_memories_list", "sreagent_docs_memories_search",
        "sreagent_commonprompts_list", "sreagent_commonprompts_get", "sreagent_workflows_generate", "sreagent_workflows_validate",
        "sreagent_architecture_plan"
    };
    public static readonly IReadOnlySet<string> WriteTools = new HashSet<string>(StringComparer.Ordinal)
    {
        "sreagent_agents_create", "sreagent_agents_delete", "sreagent_connectors_create_kusto", "sreagent_connectors_delete",
        "sreagent_connectors_test", "sreagent_skills_create", "sreagent_skills_delete",
        "sreagent_scheduledtasks_pause", "sreagent_scheduledtasks_resume", "sreagent_scheduledtasks_delete",
        "sreagent_docs_memories_add", "sreagent_docs_memories_delete", "sreagent_docs_memories_reindex",
        "sreagent_commonprompts_create", "sreagent_commonprompts_delete"
    };
    public static readonly IReadOnlyList<string> AllowedTools = ReadTools.Concat(WriteTools).ToArray();
    private readonly SemaphoreSlim connectionLock = new(1, 1);
    private readonly SreMcpRuntime runtime = new(Path.Combine(AppContext.BaseDirectory, "mcp"));
    private McpClient? client;

    private Task<string> PrepareExecutableAsync(string executable, CancellationToken cancellationToken)
    {
        if (executable != "mcp/azmcp") return Task.FromResult(executable);
        if (!OperatingSystem.IsLinux()) throw new InvalidOperationException("The bundled runtime requires Linux x64.");
        return runtime.PrepareAsync(cancellationToken);
    }

    private async Task<McpClient> ConnectAsync(CancellationToken cancellationToken)
    {
        await connectionLock.WaitAsync(cancellationToken);
        try
        {
            if (client is not null) return client;
            var executable = configuration["LabConsole:Sre:McpExecutable"];
            if (string.IsNullOrWhiteSpace(executable)) throw new InvalidOperationException("MCP executable is not configured.");
            var arguments = new List<string> { "server", "start", "--disable-proxy-tools" };
            foreach (var tool in AllowedTools) { arguments.Add("--tool"); arguments.Add(tool); }
            var hosted = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WEBSITE_INSTANCE_ID"));
            var transport = new StdioClientTransport(new StdioClientTransportOptions
            {
                Command = await PrepareExecutableAsync(executable, cancellationToken), Arguments = arguments,
                EnvironmentVariables = new Dictionary<string, string?>
                {
                    ["AZURE_TOKEN_CREDENTIALS"] = hosted ? "ManagedIdentityCredential" : "AzureCliCredential",
                    ["AZURE_CLIENT_ID"] = null,
                    ["AZURE_SUBSCRIPTION_ID"] = configuration["LabConsole:Sre:SubscriptionId"],
                    ["AZURE_TENANT_ID"] = configuration["LabConsole:Sre:TenantId"],
                    ["AZURE_MCP_COLLECT_TELEMETRY"] = "false"
                }
            });
            client = await McpClient.CreateAsync(transport, cancellationToken: cancellationToken);
            return client;
        }
        finally { connectionLock.Release(); }
    }

    public async Task<IReadOnlyList<string>> ToolsAsync(CancellationToken cancellationToken) =>
        (await (await ConnectAsync(cancellationToken)).ListToolsAsync(cancellationToken: cancellationToken)).Select(tool => tool.Name).ToArray();

    public async Task<IReadOnlyList<SreTool>> CatalogAsync(CancellationToken cancellationToken) =>
        (await (await ConnectAsync(cancellationToken)).ListToolsAsync(cancellationToken: cancellationToken))
            .Where(tool => AllowedTools.Contains(tool.Name, StringComparer.Ordinal))
            .Select(tool => new SreTool(tool.Name, tool.Description ?? tool.Name, tool.JsonSchema.Clone(), ReadTools.Contains(tool.Name))).ToArray();

    public async Task<JsonElement> CallAsync(string tool, IReadOnlyDictionary<string, object?> arguments, CancellationToken cancellationToken)
    {
        if (!AllowedTools.Contains(tool, StringComparer.Ordinal)) throw new InvalidOperationException("MCP tool is not allowed.");
        var response = await (await ConnectAsync(cancellationToken)).CallToolAsync(tool, arguments, cancellationToken: cancellationToken);
        if (response.IsError == true) throw new SreMcpException("SRE request failed. Verify identity permissions and inspect the agent in Azure.");
        JsonElement result;
        if (response.StructuredContent is not null)
            result = JsonSerializer.SerializeToElement(response.StructuredContent);
        else
        {
            var text = string.Join("\n", response.Content.OfType<TextContentBlock>().Select(block => block.Text));
            using var document = JsonDocument.Parse(text);
            result = document.RootElement.Clone();
        }
        if (result.ValueKind == JsonValueKind.Object && result.TryGetProperty("status", out var status) && status.ValueKind == JsonValueKind.Number && status.GetInt32() >= 400)
            throw new SreMcpException("SRE request failed. Verify identity permissions and inspect the agent in Azure.");
        return result;
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            if (client is not null) await client.DisposeAsync();
        }
        finally
        {
            runtime.Dispose();
            connectionLock.Dispose();
        }
    }
}

public sealed class SreMcpException(string message) : Exception(message);