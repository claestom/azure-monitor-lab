using System.ClientModel.Primitives;
using System.Net;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Microsoft.Extensions.Configuration;
using OpenAI;
using OpenAI.Chat;
using Xunit;

namespace AmlabHello.Tests;

public sealed class SreModelTests
{
    private static IConfiguration Settings(string endpoint = "https://test.openai.azure.com/") => new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
    {
        ["LabConsole:Sre:ModelEndpoint"] = endpoint, ["LabConsole:Sre:ModelDeployment"] = "gpt-5-mini"
    }).Build();

    private static SreModel Create(FakeTransport transport)
    {
    #pragma warning disable OPENAI001
        var client = new ChatClient("gpt-5-mini", new BearerTokenPolicy(new FakeCredential(), "https://ai.azure.com/.default"), new OpenAIClientOptions
        {
            Endpoint = new Uri("https://test.openai.azure.com/openai/v1/"),
            Transport = new HttpClientPipelineTransport(new HttpClient(transport)), RetryPolicy = new ClientRetryPolicy(0)
        });
    #pragma warning restore OPENAI001
        return new(Settings(), client);
    }

    [Fact]
    public async Task ModelUsesBoundedSingleToolCallsWithTheActualSdkContract()
    {
        using var transport = new FakeTransport();
        var step = await Create(transport).CompleteAsync([new UserChatMessage("List the agents")],
            [new("sreagent_agents_list", "List SRE agents", JsonDocument.Parse("""{"type":"object","properties":{}}""").RootElement.Clone(), true)], default);
        Assert.Equal("sreagent_agents_list", step.ToolCall!.FunctionName);
        Assert.Equal(123, step.InputTokens);
        Assert.Equal(24, step.OutputTokens);
        using var sent = JsonDocument.Parse(transport.Body!);
        Assert.Equal(4096, sent.RootElement.GetProperty("max_completion_tokens").GetInt32());
        Assert.False(sent.RootElement.GetProperty("parallel_tool_calls").GetBoolean());
        Assert.Single(sent.RootElement.GetProperty("tools").EnumerateArray());
        Assert.DoesNotContain("threads", transport.Uri);
        Assert.Single(transport.Requests);
    }

    [Fact]
    public async Task ModelFailuresAreNotRetried()
    {
        using var transport = new FakeTransport { Fail = true };
        await Assert.ThrowsAnyAsync<Exception>(() => Create(transport).CompleteAsync([new UserChatMessage("test")], [], default));
        Assert.Single(transport.Requests);
    }

    [Fact]
    public async Task SummaryOnlyCallCannotProduceAnExecutableToolCall()
    {
        using var transport = new FakeTransport();
        await Assert.ThrowsAsync<InvalidOperationException>(() => Create(transport).CompleteAsync([new UserChatMessage("Summarize results")], [], default));
    }

    [Theory]
    [InlineData("https://attacker.example/")]
    [InlineData("http://test.openai.azure.com/")]
    [InlineData("https://test.openai.azure.com/api/projects/project")]
    [InlineData("https://test.openai.azure.com/#fragment")]
    public void ModelEndpointMustBeAPublicAzureOpenAiAccountRoot(string endpoint)
    {
        Assert.False(new SreModel(Settings(endpoint)).Configured);
    }

    [Fact]
    public void ModelEndpointRejectsEmbeddedCredentials()
    {
        var endpoint = new UriBuilder("https://test.openai.azure.com/") { UserName = "test-user", Password = Guid.NewGuid().ToString() };
        Assert.False(new SreModel(Settings(endpoint.Uri.AbsoluteUri)).Configured);
    }

    private sealed class FakeCredential : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) => new("fake-token", DateTimeOffset.UtcNow.AddHours(1));
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) => ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }

    private sealed class FakeTransport : HttpMessageHandler
    {
        public bool Fail { get; set; }
        public string? Body { get; private set; }
        public string? Uri { get; private set; }
        public List<string> Requests { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Body = await request.Content!.ReadAsStringAsync(cancellationToken);
            Uri = request.RequestUri!.AbsoluteUri;
            Requests.Add(Uri);
            return new HttpResponseMessage(Fail ? HttpStatusCode.ServiceUnavailable : HttpStatusCode.OK)
            {
                Content = new StringContent(Fail ? "{\"error\":{\"message\":\"test failure\"}}" : """
                    {"id":"chat-test","object":"chat.completion","created":1700000000,"model":"gpt-5-mini",
                     "choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"call-test","type":"function","function":{"name":"sreagent_agents_list","arguments":"{}"}}]}}],
                     "usage":{"prompt_tokens":123,"completion_tokens":24,"total_tokens":147}}
                    """, Encoding.UTF8, "application/json")
            };
        }
    }
}