using System.Text.Json;

public sealed record StoredLabOperation(string Owner, LabOperationRun Run);

public sealed class LabOperationsJournal
{
    private readonly string path;
    private readonly string webRoot = Path.Combine(AppContext.BaseDirectory, "wwwroot");

    public LabOperationsJournal(IConfiguration configuration)
    {
        path = configuration["LabConsole:Operations:JournalPath"] ?? "";
    }

    public LabOperationsJournal(IConfiguration configuration, IWebHostEnvironment environment) : this(configuration)
    {
        webRoot = Path.GetFullPath(environment.WebRootPath ?? Path.Combine(environment.ContentRootPath, "wwwroot"));
    }

    public Lease Open()
    {
        if (!Path.IsPathFullyQualified(path)) throw new InvalidOperationException("An absolute, persistent operations journal path is required.");
        if (Path.GetFullPath(path).Equals(webRoot, StringComparison.OrdinalIgnoreCase)
            || Path.GetFullPath(path).StartsWith(webRoot.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The operations journal must be outside the public web directory.");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var file = new FileStream(path + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        try { return new Lease(path, file); }
        catch { file.Dispose(); throw; }
    }

    public sealed class Lease : IDisposable
    {
        private readonly string path;
        private readonly FileStream file;
        public List<StoredLabOperation> Runs { get; }

        public Lease(string path, FileStream file)
        {
            this.path = path;
            this.file = file;
            if (File.Exists(path))
            {
                if (new FileInfo(path).Length > 2 * 1024 * 1024) throw new InvalidOperationException("Operations journal exceeded its safety limit.");
                Runs = JsonSerializer.Deserialize<List<StoredLabOperation>>(File.ReadAllText(path)) ?? throw new InvalidOperationException("Invalid operations journal.");
            }
            else Runs = [];
        }

        public void Save()
        {
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    JsonSerializer.Serialize(output, Runs);
                    output.Flush(true);
                }
                File.Move(temporary, path, true);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }

        public void Dispose() => file.Dispose();
    }
}