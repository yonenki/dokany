using System.Security.Cryptography;
using System.Text.Json;
using Dokany.DistributionProfile;

return await DistributionProfileCli.RunAsync(args);

internal static class DistributionProfileCli
{
    private static readonly JsonSerializerOptions JsonOutput = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };

    public static Task<int> RunAsync(string[] args)
    {
        try
        {
            return Task.FromResult(Run(args));
        }
        catch (DistributionProfileValidationException exception)
        {
            Console.Error.WriteLine($"distribution-profile: {exception.Message}");
            return Task.FromResult(2);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
        {
            Console.Error.WriteLine($"distribution-profile: {exception.Message}");
            return Task.FromResult(3);
        }
    }

    private static int Run(string[] args)
    {
        if (args.Length is 2 && args[0] == "validate")
        {
            var profile = DistributionProfileLoader.Load(args[1]);
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                profile.DistributionId,
                profile.ProfileHash,
                profile.Family.BinaryBaseName,
                profile.Family.ControlBaseName,
            }, JsonOutput));
            return 0;
        }

        if (args.Length is 3 && args[0] == "generate")
        {
            var profile = DistributionProfileLoader.Load(args[1]);
            var output = DistributionProfileGenerator.Render(profile);
            WriteOutputs(args[2], output);
            return 0;
        }

        if (args.Length is 11 && args[0] == "package")
        {
            var profile = DistributionProfileLoader.Load(args[1]);
            var output = DistributionProfileGenerator.Render(profile);
            var manifest = DistributionPackageBuilder.Create(
                profile,
                output,
                new DistributionPackageInputs(
                    args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10],
                    Directory.GetCurrentDirectory()));
            Console.WriteLine(JsonSerializer.Serialize(manifest, JsonOutput));
            return 0;
        }

        Console.Error.WriteLine("Usage:");
        Console.Error.WriteLine("  DistributionProfile validate <profile.json>");
        Console.Error.WriteLine("  DistributionProfile generate <profile.json> <output-directory>");
        Console.Error.WriteLine("  DistributionProfile package <profile.json> <x64|arm64> <source-commit> <output-directory> <dll> <lib> <sys> <inf> <cat> <control-exe>");
        return 1;
    }

    private static void WriteOutputs(string outputDirectory, GeneratedDistributionProfile output)
    {
        Directory.CreateDirectory(outputDirectory);
        var files = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["dokan_distribution_profile.h"] = output.Header,
            ["dokan_distribution_profile.rs"] = output.RustConstants,
            ["Dokan.DistributionProfile.props"] = output.MsBuildProps,
            [output.InfFileName] = output.Inf,
            ["version.xml"] = output.VersionXml,
            ["runtime-identity.json"] = JsonSerializer.Serialize(output.RuntimeIdentity, JsonOutput) + Environment.NewLine,
        };

        var hashes = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var (fileName, content) in files)
        {
            WriteIfChanged(Path.Combine(outputDirectory, fileName), content);
            hashes[fileName] = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(content))).ToLowerInvariant();
        }

        WriteIfChanged(
            Path.Combine(outputDirectory, "profile.outputs.json"),
            JsonSerializer.Serialize(new { schemaVersion = 1, files = hashes }, JsonOutput) + Environment.NewLine);

        Console.WriteLine(JsonSerializer.Serialize(new
        {
            outputDirectory = Path.GetFullPath(outputDirectory),
            output.RuntimeIdentity.DistributionId,
            output.RuntimeIdentity.ProfileHash,
            files = hashes,
        }, JsonOutput));
    }

    private static void WriteIfChanged(string path, string content)
    {
        var utf8 = new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
        if (File.Exists(path) && File.ReadAllText(path, utf8) == content)
        {
            return;
        }

        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(temporaryPath, content, utf8);
            File.Move(temporaryPath, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }
}
