using Xunit;

public class InfrastructureHealthSignalTests
{
    private static readonly DateTimeOffset CheckedAt = DateTimeOffset.Parse("2026-09-11T12:00:00Z");

    [Theory]
    [InlineData(0, "healthy")]
    [InlineData(300, "healthy")]
    [InlineData(301, "warning")]
    [InlineData(900, "warning")]
    [InlineData(901, "critical")]
    public void HeartbeatsUseWorkbookBoundaries(int ageSeconds, string expected)
    {
        var signal = InfrastructureHealthSignal.Heartbeat(CheckedAt.AddSeconds(-ageSeconds), CheckedAt);
        Assert.Equal(expected, signal.State);
    }

    [Theory]
    [InlineData(0, 5, "healthy")]
    [InlineData(1, 5, "warning")]
    [InlineData(4, 5, "warning")]
    [InlineData(5, 5, "critical")]
    [InlineData(9, 10, "warning")]
    [InlineData(10, 10, "critical")]
    public void RequestFailuresUseWorkbookBoundaries(long failures, int threshold, string expected)
    {
        Assert.Equal(expected, InfrastructureHealthSignal.Requests(20, failures, threshold, CheckedAt).State);
    }

    [Theory]
    [InlineData(0, 0, "critical")]
    [InlineData(2, 5, "healthy")]
    [InlineData(2, 6, "warning")]
    public void KubernetesUsesWorkbookBoundaries(long nodes, long restarts, string expected)
    {
        Assert.Equal(expected, InfrastructureHealthSignal.Kubernetes(nodes, restarts, CheckedAt).State);
    }

    [Theory]
    [InlineData("Available", "healthy")]
    [InlineData("Degraded", "warning")]
    [InlineData("Unavailable", "critical")]
    [InlineData("Unknown", "unknown")]
    [InlineData("Unsupported", "unknown")]
    [InlineData(null, "unknown")]
    public void PlatformHealthDoesNotInventAvailability(string? availability, string expected)
    {
        Assert.Equal(expected, InfrastructureHealthSignal.Platform(availability, CheckedAt).State);
    }

    [Fact]
    public void MissingDataNeverBecomesHealthy()
    {
        Assert.Equal("unknown", InfrastructureHealthSignal.Heartbeat(null, CheckedAt).State);
        Assert.Equal("unknown", InfrastructureHealthSignal.Requests(0, 0, 5, null).State);
        Assert.Equal("unknown", InfrastructureHealthSignal.Kubernetes(2, null, CheckedAt).State);
        Assert.Equal("unknown", InfrastructureHealthSignal.Worst([]).State);
        Assert.Equal("unknown", InfrastructureHealthSignal.Worst([
            InfrastructureHealthSignal.Platform("Available", CheckedAt),
            InfrastructureHealthSignal.Unknown("Telemetry query unavailable.")]).State);
    }

    [Fact]
    public void AHealthySignalCannotHideACriticalSignal()
    {
        Assert.Equal("critical", InfrastructureHealthSignal.Worst([
            InfrastructureHealthSignal.Unknown("Telemetry query unavailable."),
            InfrastructureHealthSignal.Platform("Available", CheckedAt),
            InfrastructureHealthSignal.Heartbeat(CheckedAt.AddMinutes(-20), CheckedAt)]).State);
    }
}