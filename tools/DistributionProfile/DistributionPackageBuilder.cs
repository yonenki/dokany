using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Dokany.DistributionProfile;

public sealed record DistributionPackageInputs(
    string Architecture,
    string SourceCommit,
    string OutputDirectory,
    string RuntimeDll,
    string ImportLibrary,
    string Driver,
    string Inf,
    string Catalog,
    string ControlTool,
    string RepositoryRoot);

public sealed record DistributionPackageFile(string Role, long Size, string Sha256);

public sealed record DistributionPackageManifest(
    int SchemaVersion,
    string DistributionId,
    string ProfileHash,
    string ProductVersion,
    int ProtocolAbi,
    string Architecture,
    string SourceCommit,
    SortedDictionary<string, DistributionPackageFile> Files);

public static partial class DistributionPackageBuilder
{
    private static readonly JsonSerializerOptions JsonOutput = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };

    public static DistributionPackageManifest Create(
        DistributionProfile profile,
        GeneratedDistributionProfile generated,
        DistributionPackageInputs inputs)
    {
        ValidateInputs(profile, generated, inputs);
        var output = Path.GetFullPath(inputs.OutputDirectory);
        if (Directory.Exists(output) || File.Exists(output))
        {
            throw new DistributionProfileValidationException($"Package output already exists: {output}");
        }

        var parent = Path.GetDirectoryName(output)
            ?? throw new DistributionProfileValidationException("Package output must have a parent directory.");
        Directory.CreateDirectory(parent);
        var temporary = Path.Combine(parent, $".{Path.GetFileName(output)}.{Guid.NewGuid():N}.tmp");
        try
        {
            Directory.CreateDirectory(temporary);
            var files = new SortedDictionary<string, DistributionPackageFile>(StringComparer.Ordinal);
            CopyArtifact(inputs.RuntimeDll, $"runtime/{profile.Family.BinaryBaseName}.dll", "runtimeDll", temporary, files);
            CopyArtifact(inputs.ImportLibrary, $"sdk/{profile.Family.BinaryBaseName}.lib", "importLibrary", temporary, files);
            CopyArtifact(inputs.Driver, $"driver/{profile.Family.BinaryBaseName}.sys", "driver", temporary, files);
            CopyArtifact(inputs.Inf, $"driver/{profile.Family.BinaryBaseName}.inf", "inf", temporary, files);
            CopyArtifact(inputs.Catalog, $"driver/{profile.Family.BinaryBaseName}.cat", "catalog", temporary, files);
            CopyArtifact(inputs.ControlTool, $"tools/{profile.Family.ControlBaseName}.exe", "controlTool", temporary, files);
            CopyArtifact(Path.Combine(inputs.RepositoryRoot, "license.lgpl.txt"), "licenses/license.lgpl.txt", "license", temporary, files);
            CopyArtifact(Path.Combine(inputs.RepositoryRoot, "license.mit.txt"), "licenses/license.mit.txt", "license", temporary, files);

            WriteArtifact(
                "identity/runtime-identity.json",
                JsonSerializer.Serialize(generated.RuntimeIdentity, JsonOutput) + Environment.NewLine,
                "runtimeIdentity",
                temporary,
                files);
            WriteArtifact(
                "NOTICE.txt",
                $"{profile.DisplayName}\nSource: https://github.com/yonenki/dokany/commit/{inputs.SourceCommit}\nProfile: {profile.DistributionId} {profile.ProfileHash}\n",
                "notice",
                temporary,
                files);

            var manifest = new DistributionPackageManifest(
                1,
                profile.DistributionId,
                profile.ProfileHash,
                profile.Release.ProductVersion,
                profile.Release.ProtocolAbi,
                inputs.Architecture.ToLowerInvariant(),
                inputs.SourceCommit.ToLowerInvariant(),
                files);
            File.WriteAllText(
                Path.Combine(temporary, "artifact-manifest.json"),
                JsonSerializer.Serialize(manifest, JsonOutput) + Environment.NewLine,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            Directory.Move(temporary, output);
            return manifest;
        }
        finally
        {
            if (Directory.Exists(temporary))
            {
                Directory.Delete(temporary, recursive: true);
            }
        }
    }

    private static void ValidateInputs(
        DistributionProfile profile,
        GeneratedDistributionProfile generated,
        DistributionPackageInputs inputs)
    {
        if (inputs.Architecture is not ("x64" or "arm64"))
        {
            throw new DistributionProfileValidationException("Package architecture must be x64 or arm64.");
        }
        if (!SourceCommitPattern().IsMatch(inputs.SourceCommit))
        {
            throw new DistributionProfileValidationException("Source commit must be a full 40-character Git object ID.");
        }

        var expectedNames = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            [inputs.RuntimeDll] = $"{profile.Family.BinaryBaseName}.dll",
            [inputs.ImportLibrary] = $"{profile.Family.BinaryBaseName}.lib",
            [inputs.Driver] = $"{profile.Family.BinaryBaseName}.sys",
            [inputs.Inf] = $"{profile.Family.BinaryBaseName}.inf",
            [inputs.Catalog] = $"{profile.Family.BinaryBaseName}.cat",
            [inputs.ControlTool] = $"{profile.Family.ControlBaseName}.exe",
        };
        foreach (var (path, expectedName) in expectedNames)
        {
            if (!File.Exists(path))
            {
                throw new DistributionProfileValidationException($"Package input does not exist: {path}");
            }
            if (!string.Equals(Path.GetFileName(path), expectedName, StringComparison.OrdinalIgnoreCase))
            {
                throw new DistributionProfileValidationException($"Package input must be named {expectedName}: {path}");
            }
        }
        if (!string.Equals(File.ReadAllText(inputs.Inf), generated.Inf, StringComparison.Ordinal))
        {
            throw new DistributionProfileValidationException("Package INF differs from the selected distribution profile output.");
        }
    }

    private static void CopyArtifact(
        string source,
        string relativePath,
        string role,
        string root,
        SortedDictionary<string, DistributionPackageFile> files)
    {
        var destination = Destination(root, relativePath);
        File.Copy(source, destination, overwrite: false);
        AddFile(relativePath, role, destination, files);
    }

    private static void WriteArtifact(
        string relativePath,
        string content,
        string role,
        string root,
        SortedDictionary<string, DistributionPackageFile> files)
    {
        var destination = Destination(root, relativePath);
        File.WriteAllText(destination, content, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        AddFile(relativePath, role, destination, files);
    }

    private static string Destination(string root, string relativePath)
    {
        var destination = Path.Combine(root, relativePath.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        return destination;
    }

    private static void AddFile(
        string relativePath,
        string role,
        string path,
        SortedDictionary<string, DistributionPackageFile> files)
    {
        using var stream = File.OpenRead(path);
        files.Add(
            relativePath,
            new DistributionPackageFile(role, stream.Length, Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant()));
    }

    [GeneratedRegex("^[0-9a-fA-F]{40}$", RegexOptions.CultureInvariant)]
    private static partial Regex SourceCommitPattern();
}
