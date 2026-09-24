using System.Net;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Azure.Core.Pipeline;
using Azure.Monitor.Query.Logs;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace AmlabHello.Tests;

public sealed class InfrastructureHealthServiceTests
{
    private static readonly string Subscription = Guid.NewGuid().ToString();
    private static readonly string Scope = $"/subscriptions/{Subscription}/resourceGroups/test-rg";
    private static readonly string Workspace = $"{Scope}/providers/Microsoft.OperationalInsights/workspaces/central";
    private static readonly string Machine = $"{Scope}/providers/Microsoft.Compute/virtualMachines/test-vm";
    private static readonly string App = $"{Scope}/providers/Microsoft.Web/sites/test-app";
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-09-11T12:00:00Z");

    private static InfrastructureHealthService Create(FakeAzure transport, FakeClock? clock = null, Action<Dictionary<string, string?>>? configure = null, FakeCredential? credential = null)
    {
        var settings = new Dictionary<string, string?>
        {
            ["LabConsole:Health:Enabled"] = "true", ["LabConsole:Health:SubscriptionId"] = Subscription,
            ["LabConsole:ResourceGroup"] = "test-rg", ["LabConsole:Health:CentralWorkspaceResourceId"] = Workspace
        };
        configure?.Invoke(settings);
        credential ??= new FakeCredential();
        var http = new HttpClient(transport);
        var logs = new LogsQueryClient(credential, new LogsQueryClientOptions { Transport = new HttpClientTransport(http), Retry = { MaxRetries = 0 } });
        return new(new ConfigurationBuilder().AddInMemoryCollection(settings).Build(), http, credential, logs, clock ?? new FakeClock());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SdkDeserializesTheHealthQueryResponse(bool partial)
    {
        using var transport = new FakeAzure { PartialLogs = partial };
        var logs = new LogsQueryClient(new FakeCredential(), new LogsQueryClientOptions { Transport = new HttpClientTransport(new HttpClient(transport)), Retry = { MaxRetries = 0 } });
        var result = await logs.QueryWorkspaceAsync(Guid.NewGuid().ToString(), InfrastructureHealthQueries.Build("Heartbeat", Scope),
            new LogsQueryTimeRange(TimeSpan.FromHours(1)), new LogsQueryOptions { AllowPartialErrors = true });
        Assert.Equal(partial, result.Value.Status != Azure.Monitor.Query.Logs.Models.LogsQueryResultStatus.Success);
        Assert.Single(result.Value.Table.Rows);
    }

    [Fact]
    public async Task CombinesWorkbookSignalsAndPlatformAvailabilityWithinTheConfiguredScope()
    {
        using var transport = new FakeAzure();
        var result = await Create(transport).CheckAsync(default);
        Assert.True(result.Available);
        Assert.Equal("ready", result.State);
        Assert.Equal(2, result.Resources.Count);
        Assert.Equal("critical", result.Resources.Single(resource => resource.Id == App).State);
        Assert.Equal("healthy", result.Resources.Single(resource => resource.Id == Machine).State);
        Assert.Contains("6 failures", result.Resources.Single(resource => resource.Id == App).Telemetry!.Detail);
        Assert.All(result.Resources, resource => Assert.StartsWith("https://portal.azure.com/#resource" + Scope, resource.PortalUrl));
        Assert.Equal(2, transport.Queries.Count);
        Assert.All(transport.Queries, query =>
        {
            Assert.Contains("_ResourceId startswith", query);
            Assert.Contains(Scope + "/providers/", query);
            Assert.Contains("| take 501", query);
            Assert.DoesNotContain("workspace(", query);
        });
        Assert.All(transport.ArmRequests, request => Assert.Equal("GET", request.Method));
        Assert.All(transport.ArmRequests, request => Assert.StartsWith("https://management.azure.com" + Scope, request.Uri));
    }

    [Fact]
    public async Task IncludesOnlyVirtualMachinesScaleSetsClustersAndWebApps()
    {
        using var transport = new FakeAzure
        {
            AdditionalResources = [
                new { id = $"{Scope}/providers/Microsoft.Compute/virtualMachineScaleSets/test-vmss", name = "test-vmss", type = "MICROSOFT.COMPUTE/VIRTUALMACHINESCALESETS" },
                new { id = $"{Scope}/providers/Microsoft.ContainerService/managedClusters/test-aks", name = "test-aks", type = "microsoft.containerservice/managedclusters" },
                new { id = Workspace, name = "central", type = "Microsoft.OperationalInsights/workspaces" },
                new { id = $"{Scope}/providers/Microsoft.Insights/components/test-appi", name = "test-appi", type = "Microsoft.Insights/components" },
                new { id = $"{Scope}/providers/Microsoft.Storage/storageAccounts/test-storage", name = "test-storage", type = "Microsoft.Storage/storageAccounts" },
                new { id = $"{Scope}/providers/Microsoft.Web/serverfarms/test-plan", name = "test-plan", type = "Microsoft.Web/serverfarms" },
                new { id = $"{Scope}/providers/Microsoft.Network/networkInterfaces/test-nic", name = "test-nic", type = "Microsoft.Network/networkInterfaces" }
            ]
        };
        var result = await Create(transport).CheckAsync(default);
        Assert.Equal("ready", result.State);
        Assert.Equal(new[] { "test-aks", "test-app", "test-vm", "test-vmss" }, result.Resources.Select(resource => resource.Name).Order());
        Assert.Equal(3, transport.Queries.Count);
        Assert.DoesNotContain(transport.Queries, query => query.StartsWith("AppRequests"));
        Assert.DoesNotContain(result.Sources, source => source.Name is "App Insights" or "Application workspace");
        Assert.Null(result.Resources.Single(resource => resource.Name == "test-vmss").Telemetry);
    }

    [Fact]
    public async Task CachesSuccessfulChecksAndRefreshesOnlyAfterExpiry()
    {
        using var transport = new FakeAzure();
        var clock = new FakeClock();
        var service = Create(transport, clock);
        var first = await service.CheckAsync(default);
        var requests = transport.ArmRequests.Count;
        var cached = await Task.WhenAll(Enumerable.Range(0, 4).Select(_ => service.CheckAsync(default)));
        Assert.All(cached, result => Assert.True(result.Cached));
        Assert.All(cached, result => Assert.Equal(first.CheckedAt, result.CheckedAt));
        Assert.Equal(requests, transport.ArmRequests.Count);
        clock.Current = Now.AddSeconds(61);
        Assert.False((await service.CheckAsync(default)).Cached);
        Assert.Equal(requests * 2, transport.ArmRequests.Count);
    }

    [Theory]
    [InlineData("LabConsole:Health:Enabled", "false")]
    [InlineData("LabConsole:Health:SubscriptionId", "invalid")]
    [InlineData("LabConsole:ResourceGroup", "test-rg/../other")]
    public async Task DisabledOrInvalidScopeNeverContactsAzure(string setting, string value)
    {
        using var transport = new FakeAzure();
        var result = await Create(transport, configure: settings => settings[setting] = value).CheckAsync(default);
        Assert.False(result.Available);
        Assert.Equal("not_configured", result.State);
        Assert.Empty(transport.ArmRequests);
        Assert.Empty(transport.Queries);
    }

    [Fact]
    public async Task ReusesArmAuthenticationUntilTheTokenNeedsRefresh()
    {
        using var transport = new FakeAzure();
        var clock = new FakeClock { Current = DateTimeOffset.UtcNow };
        var credential = new FakeCredential { ExpiresAt = clock.Current.AddHours(1) };
        var service = Create(transport, clock, credential: credential);
        await service.CheckAsync(default);
        Assert.Equal(3, transport.ArmRequests.Count);
        Assert.Equal(1, credential.ArmTokenRequests);
        clock.Current = clock.Current.AddMinutes(2);
        await service.CheckAsync(default);
        Assert.Equal(1, credential.ArmTokenRequests);
        clock.Current = credential.ExpiresAt.AddMinutes(-4);
        credential.ExpiresAt = clock.Current.AddHours(1);
        await service.CheckAsync(default);
        Assert.Equal(2, credential.ArmTokenRequests);
    }

    [Fact]
    public async Task CrossGroupWorkspaceIsNotQueriedAndDoesNotProduceAnAllClear()
    {
        using var transport = new FakeAzure();
        var result = await Create(transport, configure: settings => settings["LabConsole:Health:CentralWorkspaceResourceId"] = Workspace.Replace("test-rg", "other-rg")).CheckAsync(default);
        Assert.Equal("partial", result.State);
        Assert.All(result.Resources, resource => Assert.Equal("unknown", resource.State));
        Assert.Empty(transport.Queries);
        Assert.DoesNotContain(transport.ArmRequests, request => request.Uri.Contains("other-rg"));
    }

    [Theory]
    [InlineData(403)]
    [InlineData(429)]
    [InlineData(500)]
    public async Task InventoryFailureIsUnavailableAndSanitized(int status)
    {
        using var transport = new FakeAzure { InventoryStatus = status };
        var service = Create(transport);
        var result = await service.CheckAsync(default);
        Assert.False(result.Available);
        Assert.Equal("unavailable", result.State);
        Assert.Null(result.CheckedAt);
        Assert.DoesNotContain("private-diagnostic", JsonSerializer.Serialize(result));
        Assert.True((await service.CheckAsync(default)).Cached);
        Assert.Single(transport.ArmRequests);
    }

    [Fact]
    public async Task PartialTelemetryIsNeverTreatedAsACompleteHealthySignal()
    {
        using var transport = new FakeAzure { PartialLogs = true };
        var result = await Create(transport).CheckAsync(default);
        Assert.Equal("partial", result.State);
        Assert.All(result.Resources, resource => Assert.Equal("unknown", resource.State));
        Assert.Contains(result.Sources, source => !source.Available && source.Detail.Contains("partial"));
    }

    [Fact]
    public async Task MissingTablesAndEmptyTelemetryAreNotHealthy()
    {
        using var transport = new FakeAzure { EmptyLogs = true };
        var result = await Create(transport).CheckAsync(default);
        Assert.All(result.Resources, resource => Assert.Equal("unknown", resource.State));
        transport.LogStatus = 400;
        result = await Create(transport).CheckAsync(default);
        Assert.Equal("partial", result.State);
        Assert.All(result.Resources, resource => Assert.Equal("unknown", resource.State));
    }

    [Fact]
    public async Task PlatformFailureCannotHideBehindHealthyTelemetry()
    {
        using var transport = new FakeAzure { HealthStatus = 403 };
        var result = await Create(transport).CheckAsync(default);
        Assert.Equal("partial", result.State);
        Assert.Equal("unknown", result.Resources.Single(resource => resource.Id == Machine).State);
        Assert.Equal("critical", result.Resources.Single(resource => resource.Id == App).State);
    }

    [Fact]
    public async Task StalePlatformReportIsLabeledUnknownWithItsOriginalTimestamp()
    {
        using var transport = new FakeAzure { ReportedAt = Now.AddHours(-1) };
        var result = await Create(transport).CheckAsync(default);
        Assert.All(result.Resources, resource => Assert.Equal("unknown", resource.Platform.State));
        Assert.All(result.Resources, resource => Assert.Equal(Now.AddHours(-1), resource.Platform.ObservedAt));
    }

    [Fact]
    public async Task MaliciousPaginationCannotExfiltrateTheAzureToken()
    {
        using var transport = new FakeAzure { NextLink = "https://attacker.example/resources" };
        var result = await Create(transport).CheckAsync(default);
        Assert.False(result.Available);
        Assert.Single(transport.ArmRequests);
    }

    [Fact]
    public void ContinuationsMustKeepTheHostAndExactScopedPath()
    {
        var first = new Uri($"https://management.azure.com{Scope}/resources?api-version=2021-04-01");
        Assert.True(InfrastructureHealthService.SafeContinuation(new Uri(first + "&$skiptoken=next"), first));
        Assert.False(InfrastructureHealthService.SafeContinuation(new Uri(first.AbsoluteUri.Replace("test-rg", "other-rg")), first));
        Assert.False(InfrastructureHealthService.SafeContinuation(new Uri(first.AbsoluteUri.Replace("https:", "http:")), first));
        Assert.False(InfrastructureHealthService.SafeContinuation(new Uri(first + "#fragment"), first));
        Assert.False(InfrastructureHealthService.SafeContinuation(new UriBuilder(first) { UserName = "test-user" }.Uri, first));
    }

    private sealed class FakeClock : TimeProvider
    {
        public DateTimeOffset Current { get; set; } = Now;
        public override DateTimeOffset GetUtcNow() => Current;
    }

    private sealed class FakeCredential : TokenCredential
    {
        public DateTimeOffset ExpiresAt { get; set; } = DateTimeOffset.UtcNow.AddHours(1);
        public int ArmTokenRequests { get; private set; }
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            if (requestContext.Scopes.Contains("https://management.azure.com/.default")) ArmTokenRequests++;
            return new("test-token", ExpiresAt);
        }
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) => ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }

    private sealed class FakeAzure : HttpMessageHandler
    {
        public List<(string Method, string Uri)> ArmRequests { get; } = [];
        public List<string> Queries { get; } = [];
        public List<object> AdditionalResources { get; init; } = [];
        public int InventoryStatus { get; set; } = 200;
        public int HealthStatus { get; set; } = 200;
        public int LogStatus { get; set; } = 200;
        public bool PartialLogs { get; set; }
        public bool EmptyLogs { get; set; }
        public DateTimeOffset ReportedAt { get; set; } = Now;
        public string? NextLink { get; set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var uri = request.RequestUri!;
            if (uri.Host == "management.azure.com")
            {
                ArmRequests.Add((request.Method.Method, uri.AbsoluteUri));
                if (uri.AbsolutePath.EndsWith("/resources")) return Json(InventoryStatus, new
                {
                    value = new[]
                    {
                        new { id = Machine, name = "test-vm", type = "Microsoft.Compute/virtualMachines", location = "northeurope" },
                        new { id = App, name = "test-app", type = "Microsoft.Web/sites", location = "westeurope" }
                    }.Cast<object>().Concat(AdditionalResources), nextLink = NextLink
                });
                if (uri.AbsolutePath.EndsWith("/availabilityStatuses")) return Json(HealthStatus, new
                {
                    value = new[] { Machine, App }.Select(id => new
                    {
                        id = id + "/providers/Microsoft.ResourceHealth/availabilityStatuses/current",
                        properties = new { availabilityState = "Available", reportedTime = ReportedAt }
                    })
                });
                Assert.Equal(Workspace, uri.AbsolutePath);
                return Json(200, new { properties = new { customerId = Guid.NewGuid().ToString() } });
            }
            Assert.Contains(uri.Host, new[] { "api.loganalytics.io", "api.loganalytics.azure.com" });
            Assert.Equal(HttpMethod.Post, request.Method);
            using var document = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(cancellationToken));
            var query = document.RootElement.GetProperty("query").GetString()!;
            Queries.Add(query);
            var isVm = query.StartsWith("Heartbeat");
            return Json(LogStatus, new
            {
                tables = new[] { new
                {
                    name = "PrimaryResult", columns = new[]
                    {
                        new { name = "ResourceId", type = "string" }, new { name = "LastSeen", type = "datetime" },
                        new { name = "Total", type = "long" }, new { name = "Failed", type = "long" }, new { name = "Restarts", type = "long" }
                    },
                    rows = EmptyLogs ? Array.Empty<object?[]>() : new[] { new object?[] { isVm ? Machine : App, Now.AddMinutes(-1), isVm ? 0 : 20, isVm ? 0 : 6, null } }
                } }, error = PartialLogs ? new { code = "PartialError", message = "private-diagnostic" } : null
            });
        }

        private static HttpResponseMessage Json(int status, object body) => new((HttpStatusCode)status)
        {
            Content = new StringContent(JsonSerializer.Serialize(status == 200 ? body : new { error = new { code = "ReadFailed", message = "private-diagnostic" } },
                new JsonSerializerOptions { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull }), Encoding.UTF8, "application/json")
        };
    }
}