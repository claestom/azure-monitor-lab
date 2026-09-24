using System.Text.Json;

public static class InfrastructureHealthQueries
{
    public static string Build(string kind, string resourcePrefix)
    {
        var scope = JsonSerializer.Serialize(resourcePrefix);
        var filter = $"| where _ResourceId startswith {scope}";
        return kind switch
        {
            "Heartbeat" => $$"""
                Heartbeat
                | where TimeGenerated > ago(1h)
                {{filter}}
                | summarize LastSeen = max(TimeGenerated) by ResourceId = tolower(_ResourceId)
                | project ResourceId, LastSeen, Total = long(0), Failed = long(0), Restarts = long(null)
                | take 501
                """,
            "AKS" => $$"""
                let nodes = Perf
                  | where TimeGenerated > ago(15m)
                  {{filter}}
                  | where ObjectName == "K8SNode" and CounterName == "cpuUsageNanoCores"
                  | summarize Total = dcount(Computer), LastSeen = max(TimeGenerated) by ResourceId = tolower(_ResourceId);
                let pods = KubePodInventory
                  | where TimeGenerated > ago(15m)
                  {{filter}}
                  | summarize MaxRestarts = max(tolong(ContainerRestartCount)) by ResourceId = tolower(_ResourceId), Namespace, Name
                  | summarize Restarts = sum(MaxRestarts) by ResourceId;
                nodes
                | join kind=leftouter pods on ResourceId
                | project ResourceId, LastSeen, Total, Failed = long(0), Restarts
                | take 501
                """,
            "App Service" => $$"""
                AppServiceHTTPLogs
                | where TimeGenerated > ago(15m)
                {{filter}}
                | summarize Total = count(), Failed = countif(ScStatus >= 500), LastSeen = max(TimeGenerated) by ResourceId = tolower(_ResourceId)
                | project ResourceId, LastSeen, Total, Failed, Restarts = long(null)
                | take 501
                """,
            "App Insights" => $$"""
                AppRequests
                | where TimeGenerated > ago(15m)
                {{filter}}
                | summarize Total = count(), Failed = countif(Success == false), LastSeen = max(TimeGenerated) by ResourceId = tolower(_ResourceId)
                | project ResourceId, LastSeen, Total, Failed, Restarts = long(null)
                | take 501
                """,
            _ => throw new ArgumentException("Unsupported health query.", nameof(kind))
        };
    }
}