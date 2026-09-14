using Xunit;

namespace AmlabHello.Tests;

public sealed class SreMcpRuntimeTests : IDisposable
{
    private readonly string sourceDirectory = Directory.CreateTempSubdirectory("amlab-mcp-source-test-").FullName;

    [Fact]
    public async Task CompletedRuntimeIsReusedAndRemovedOnDisposal()
    {
        var sourceCommand = Path.Combine(sourceDirectory, "azmcp");
        await File.WriteAllTextAsync(sourceCommand, "test-runtime");
        Directory.CreateDirectory(Path.Combine(sourceDirectory, "assets"));
        await File.WriteAllTextAsync(Path.Combine(sourceDirectory, "assets", "dependency.txt"), "test-dependency");
        using var runtime = new SreMcpRuntime(sourceDirectory);

        var command = await runtime.PrepareAsync(default);
        var preparedDirectory = Path.GetDirectoryName(command)!;
        Assert.Equal("test-runtime", await File.ReadAllTextAsync(command));
        Assert.Equal("test-dependency", await File.ReadAllTextAsync(Path.Combine(preparedDirectory, "assets", "dependency.txt")));
        if (OperatingSystem.IsLinux())
        {
            var privateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute;
            Assert.Equal(privateMode, File.GetUnixFileMode(preparedDirectory));
            Assert.Equal(privateMode, File.GetUnixFileMode(command));
        }

        File.Delete(sourceCommand);
        Assert.Equal(command, await runtime.PrepareAsync(default));
        Assert.Equal("test-runtime", await File.ReadAllTextAsync(command));
        runtime.Dispose();
        Assert.False(Directory.Exists(preparedDirectory));
        Assert.True(Directory.Exists(sourceDirectory));
    }

    [Fact]
    public async Task CancelledPreparationRemovesPartialCopyAndCanRetry()
    {
        await File.WriteAllTextAsync(Path.Combine(sourceDirectory, "azmcp"), "test-runtime");
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var block = true;
        string? partialDirectory = null;
        using var runtime = new SreMcpRuntime(sourceDirectory, async (source, target, cancellationToken) =>
        {
            partialDirectory = Path.GetDirectoryName(target);
            await File.WriteAllTextAsync(target, "partial", cancellationToken);
            started.TrySetResult();
            if (block) await Task.Delay(Timeout.Infinite, cancellationToken);
            await File.WriteAllTextAsync(target, await File.ReadAllTextAsync(source, cancellationToken), cancellationToken);
        });
        using var cancellation = new CancellationTokenSource();
        var preparation = runtime.PrepareAsync(cancellation.Token);
        await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => preparation);
        Assert.NotNull(partialDirectory);
        Assert.False(Directory.Exists(partialDirectory));

        block = false;
        var command = await runtime.PrepareAsync(default);
        Assert.Equal("test-runtime", await File.ReadAllTextAsync(command));
    }

    [Fact]
    public async Task FailedPreparationRemovesPartialCopyAndCanRetry()
    {
        await File.WriteAllTextAsync(Path.Combine(sourceDirectory, "azmcp"), "test-runtime");
        var fail = true;
        string? partialDirectory = null;
        using var runtime = new SreMcpRuntime(sourceDirectory, async (source, target, cancellationToken) =>
        {
            partialDirectory = Path.GetDirectoryName(target);
            await File.WriteAllTextAsync(target, "partial", cancellationToken);
            if (fail) throw new IOException("Test copy failure.");
            await File.WriteAllTextAsync(target, await File.ReadAllTextAsync(source, cancellationToken), cancellationToken);
        });
        await Assert.ThrowsAsync<IOException>(() => runtime.PrepareAsync(default));
        Assert.NotNull(partialDirectory);
        Assert.False(Directory.Exists(partialDirectory));

        fail = false;
        var command = await runtime.PrepareAsync(default);
        Assert.Equal("test-runtime", await File.ReadAllTextAsync(command));
    }

    [Fact]
    public async Task MissingRuntimeDoesNotPublishAPreparedDirectory()
    {
        using var runtime = new SreMcpRuntime(sourceDirectory);
        await Assert.ThrowsAsync<InvalidOperationException>(() => runtime.PrepareAsync(default));
        await File.WriteAllTextAsync(Path.Combine(sourceDirectory, "azmcp"), "test-runtime");
        Assert.Equal("test-runtime", await File.ReadAllTextAsync(await runtime.PrepareAsync(default)));
    }

    [Fact]
    public async Task CancelledRequestDoesNotBeginCopying()
    {
        await File.WriteAllTextAsync(Path.Combine(sourceDirectory, "azmcp"), "test-runtime");
        var copies = 0;
        using var runtime = new SreMcpRuntime(sourceDirectory, (_, _, _) =>
        {
            copies++;
            return Task.CompletedTask;
        });
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => runtime.PrepareAsync(cancellation.Token));
        Assert.Equal(0, copies);
    }

    public void Dispose() => Directory.Delete(sourceDirectory, true);
}