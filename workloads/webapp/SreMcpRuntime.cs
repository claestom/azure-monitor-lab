internal sealed class SreMcpRuntime(string sourceDirectory,
    Func<string, string, CancellationToken, Task>? copy = null) : IDisposable
{
    private readonly Func<string, string, CancellationToken, Task> copyFile = copy ?? CopyFileAsync;
    private string? runtimeDirectory;
    private bool disposed;

    public async Task<string> PrepareAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        cancellationToken.ThrowIfCancellationRequested();
        if (runtimeDirectory is not null) return Path.Combine(runtimeDirectory, "azmcp");
        if (!File.Exists(Path.Combine(sourceDirectory, "azmcp"))) throw new InvalidOperationException("The bundled MCP runtime is missing.");

        var staging = Directory.CreateTempSubdirectory("amlab-sre-mcp-").FullName;
        try
        {
            if (OperatingSystem.IsLinux())
                File.SetUnixFileMode(staging, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            foreach (var source in Directory.EnumerateFiles(sourceDirectory, "*", SearchOption.AllDirectories))
            {
                cancellationToken.ThrowIfCancellationRequested();
                var target = Path.Combine(staging, Path.GetRelativePath(sourceDirectory, source));
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                await copyFile(source, target, cancellationToken);
            }
            cancellationToken.ThrowIfCancellationRequested();
            var command = Path.Combine(staging, "azmcp");
            if (OperatingSystem.IsLinux())
                File.SetUnixFileMode(command, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            runtimeDirectory = staging;
            return command;
        }
        catch
        {
            Directory.Delete(staging, true);
            throw;
        }
    }

    private static async Task CopyFileAsync(string source, string target, CancellationToken cancellationToken)
    {
        await using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read,
            81920, FileOptions.Asynchronous | FileOptions.SequentialScan);
        await using var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None,
            81920, FileOptions.Asynchronous | FileOptions.SequentialScan);
        await input.CopyToAsync(output, cancellationToken);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        if (runtimeDirectory is not null && Directory.Exists(runtimeDirectory)) Directory.Delete(runtimeDirectory, true);
    }
}