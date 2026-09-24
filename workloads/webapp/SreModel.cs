using Azure.Core;
using Azure.Identity;
using OpenAI;
using OpenAI.Chat;
using System.ClientModel.Primitives;

public sealed record SreModelStep(string Text, ChatToolCall? ToolCall, int? InputTokens, int? OutputTokens);

public interface ISreModel
{
    bool Configured { get; }
    string Deployment { get; }
    Task<SreModelStep> CompleteAsync(IReadOnlyList<ChatMessage> messages, IReadOnlyList<SreTool> tools, CancellationToken cancellationToken);
}

public sealed class SreModel(IConfiguration configuration, ChatClient? configuredClient = null) : ISreModel
{
    private ChatClient? client;
    public string Deployment => configuration["LabConsole:Sre:ModelDeployment"] ?? "";
    public bool Configured => Endpoint is not null && !string.IsNullOrWhiteSpace(Deployment);
    private Uri? Endpoint => Uri.TryCreate(configuration["LabConsole:Sre:ModelEndpoint"], UriKind.Absolute, out var endpoint)
        && endpoint.Scheme == "https" && endpoint.Host.EndsWith(".openai.azure.com", StringComparison.OrdinalIgnoreCase)
        && endpoint.AbsolutePath == "/" && endpoint.IsDefaultPort && endpoint.UserInfo.Length == 0
        && endpoint.Query.Length == 0 && endpoint.Fragment.Length == 0 ? endpoint : null;

    private ChatClient GetClient()
    {
        if (!Configured) throw new InvalidOperationException("The MCP host model is not configured.");
        TokenCredential credential = string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WEBSITE_INSTANCE_ID"))
            ? new AzureCliCredential(new AzureCliCredentialOptions { TenantId = configuration["LabConsole:Sre:TenantId"] })
            : new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned);
    #pragma warning disable OPENAI001
        return client ??= configuredClient ?? new ChatClient(Deployment, new BearerTokenPolicy(credential, "https://ai.azure.com/.default"), new OpenAIClientOptions
        {
            Endpoint = new Uri(Endpoint!, "openai/v1/"), RetryPolicy = new ClientRetryPolicy(0), NetworkTimeout = TimeSpan.FromSeconds(75)
        });
    #pragma warning restore OPENAI001
    }

    public async Task<SreModelStep> CompleteAsync(IReadOnlyList<ChatMessage> messages, IReadOnlyList<SreTool> tools, CancellationToken cancellationToken)
    {
        var options = new ChatCompletionOptions { MaxOutputTokenCount = 4096 };
        if (tools.Count > 0)
        {
            options.AllowParallelToolCalls = false;
            foreach (var tool in tools)
                options.Tools.Add(ChatTool.CreateFunctionTool(tool.Name, tool.Description, BinaryData.FromString(tool.InputSchema.GetRawText())));
        }
        var completion = (await GetClient().CompleteChatAsync(messages, options, cancellationToken)).Value;
        if (completion.FinishReason != ChatFinishReason.Stop && completion.FinishReason != ChatFinishReason.ToolCalls)
            throw new InvalidOperationException("The model did not return a complete response.");
        if (completion.ToolCalls.Count > 1 || (tools.Count == 0 && completion.ToolCalls.Count != 0))
            throw new InvalidOperationException("The model returned an unexpected tool call.");
        var text = string.Join("\n", completion.Content.Select(part => part.Text));
        return new(text.Length > 24000 ? text[..24000] : text, completion.ToolCalls.SingleOrDefault(),
            completion.Usage?.InputTokenCount, completion.Usage?.OutputTokenCount);
    }
}