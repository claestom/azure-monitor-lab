public sealed record InfrastructureHealthSignal(string State, string Detail, DateTimeOffset? ObservedAt)
{
    public static InfrastructureHealthSignal Unknown(string detail) => new("unknown", detail, null);

    public static InfrastructureHealthSignal Heartbeat(DateTimeOffset? lastBeat, DateTimeOffset checkedAt)
    {
        if (lastBeat is null) return Unknown("No VM heartbeat in the last hour.");
        var seconds = Math.Max(0, (long)(checkedAt - lastBeat.Value).TotalSeconds);
        return new(seconds <= 300 ? "healthy" : seconds <= 900 ? "warning" : "critical",
            $"Last heartbeat {seconds}s ago.", lastBeat);
    }

    public static InfrastructureHealthSignal Requests(long total, long failed, int criticalThreshold, DateTimeOffset? lastSample)
    {
        if (total <= 0 || lastSample is null) return Unknown("No requests recorded in the last 15 minutes.");
        if (failed < 0 || failed > total) return Unknown("Request counts could not be verified.");
        return new(failed >= criticalThreshold ? "critical" : failed > 0 ? "warning" : "healthy",
            $"{total} requests / {failed} failures in the last 15 minutes.", lastSample);
    }

    public static InfrastructureHealthSignal Kubernetes(long nodes, long? restarts, DateTimeOffset? lastSample)
    {
        if (nodes == 0) return new("critical", "No AKS nodes reporting in the last 15 minutes. Verify node health and collection.", lastSample);
        if (lastSample is null || restarts is null) return Unknown("AKS node or pod inventory data is unavailable.");
        return new(restarts > 5 ? "warning" : "healthy",
            $"{nodes} nodes reporting / {restarts} reported restarts (15-minute sample window).", lastSample);
    }

    public static InfrastructureHealthSignal Platform(string? availability, DateTimeOffset? reportedAt)
    {
        var state = availability?.ToLowerInvariant() switch
        {
            "available" => "healthy",
            "degraded" => "warning",
            "unavailable" => "critical",
            _ => "unknown"
        };
        return new(state, state == "unknown" ? "Azure Resource Health has no availability assessment." : $"Azure Resource Health: {availability}.", reportedAt);
    }

    public static InfrastructureHealthSignal Worst(IEnumerable<InfrastructureHealthSignal> signals) => signals
        .OrderBy(signal => signal.State switch { "critical" => 0, "warning" => 1, "unknown" => 2, _ => 3 })
        .FirstOrDefault() ?? Unknown("No health signal is available for this resource.");
}