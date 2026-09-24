using Azure.Core;
using System.Text.RegularExpressions;

public sealed record ContainerJobTarget(string JobResourceId, string Image, string SubscriptionId, string TenantId, string ResourceGroup)
{
    public static ContainerJobTarget? FromConfiguration(IConfiguration configuration)
    {
        var section = configuration.GetSection("LabConsole:Operations");
        var jobId = section["JobResourceId"] ?? "";
        var image = section["Image"] ?? "";
        var group = configuration["LabConsole:ResourceGroup"] ?? "";
        if (!Guid.TryParse(section["TenantId"], out var tenant) || tenant == Guid.Empty
            || !Regex.IsMatch(group, "^[a-zA-Z0-9_().-]{1,90}$") || group.EndsWith('.')
            || !Regex.IsMatch(image, "^[a-z0-9][a-z0-9.-]+/[a-z0-9][a-z0-9._/-]*@sha256:[a-f0-9]{64}$")
            || jobId.IndexOfAny(['?', '#', '%', '\\']) >= 0 || jobId.Contains("/../") || jobId.Contains("/./")) return null;
        try
        {
            var resource = new ResourceIdentifier(jobId);
            if (!Guid.TryParse(resource.SubscriptionId, out var subscription) || subscription == Guid.Empty
                || !resource.ResourceType.ToString().Equals("Microsoft.App/jobs", StringComparison.OrdinalIgnoreCase)
                || !string.Equals(resource.ResourceGroupName, group, StringComparison.OrdinalIgnoreCase)
                || !string.Equals(resource.Parent?.ResourceType.ToString(), "Microsoft.Resources/resourceGroups", StringComparison.OrdinalIgnoreCase)) return null;
            return new(resource.ToString(), image, subscription.ToString(), tenant.ToString(), group);
        }
        catch (Exception exception) when (exception is ArgumentException or FormatException) { return null; }
    }
}