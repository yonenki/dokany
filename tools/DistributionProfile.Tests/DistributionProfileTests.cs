using System.Security.Cryptography;
using System.Text.Json;
using Dokany.DistributionProfile;
using Xunit;

namespace Dokany.DistributionProfile.Tests;

public sealed class DistributionProfileTests
{
    private static string RepositoryRoot => Path.GetFullPath(
        Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));

    [Theory]
    [InlineData("upstream.json", "dokany", "dokan2", "Dokan2", "Dokan_2")]
    [InlineData("vendor.json", "acmefs", "acmefs2", "AcmeFs2", "AcmeFs_2")]
    public void LoadsValidatedProfiles(
        string fileName,
        string distributionId,
        string binaryBaseName,
        string serviceName,
        string deviceName)
    {
        var profile = DistributionProfileLoader.Load(
            ProfilePath(fileName));

        Assert.Equal(distributionId, profile.DistributionId);
        Assert.Equal(binaryBaseName, profile.Family.BinaryBaseName);
        Assert.Equal(serviceName, profile.Family.ServiceName);
        Assert.Equal(deviceName, profile.Derived.GlobalDeviceName);
        Assert.Equal(64, profile.ProfileHash.Length);
    }

    [Fact]
    public void CanonicalHashDoesNotDependOnJsonFormattingOrPropertyOrder()
    {
        var originalPath = ProfilePath("vendor.json");
        var original = DistributionProfileLoader.Load(originalPath);
        using var document = JsonDocument.Parse(File.ReadAllText(originalPath));
        var reordered = JsonSerializer.Serialize(
            document.RootElement.EnumerateObject().Reverse().ToDictionary(x => x.Name, x => x.Value),
            new JsonSerializerOptions { WriteIndented = false });
        var reorderedPath = Path.Combine(Path.GetTempPath(), $"dokany-profile-{Guid.NewGuid():N}.json");

        try
        {
            File.WriteAllText(reorderedPath, reordered);
            var loaded = DistributionProfileLoader.Load(reorderedPath);
            Assert.Equal(original.ProfileHash, loaded.ProfileHash);
        }
        finally
        {
            File.Delete(reorderedPath);
        }
    }

    [Fact]
    public void ExternalVendorProfileGeneratesOneConsistentIdentitySet()
    {
        var profile = DistributionProfileLoader.Load(
            ProfilePath("vendor.json"));
        var output = DistributionProfileGenerator.Render(profile);

        Assert.Contains("#define DOKAN_DIST_BINARY_BASENAME_W L\"acmefs2\"", output.Header);
        Assert.Contains("#define DOKAN_DIST_GLOBAL_DEVICE_WIN32_W L\"\\\\\\\\.\\\\AcmeFs_2\"", output.Header);
        Assert.Contains("pub const DOKAN_BINARY_BASENAME: &str = \"acmefs2\";", output.RustConstants);
        Assert.Contains($"pub const DOKAN_PROFILE_HASH_HEX: &str = \"{profile.ProfileHash}\";", output.RustConstants);
        Assert.Contains("<DokanBinaryBaseName>acmefs2</DokanBinaryBaseName>", output.MsBuildProps);
        Assert.Contains("<DokanControlBaseName>acmectl</DokanControlBaseName>", output.MsBuildProps);
        Assert.Contains("ProviderName       = \"Acme\"", output.Inf);
        Assert.Contains("DriverName         = \"acmefs2\"", output.Inf);
        Assert.Contains("DriverVer         = 07/23/2026,2.3.1.1000", output.Inf);
        Assert.Contains("[DefaultInstall.NT$ARCH$.Services]", output.Inf);
        Assert.Contains("AddService = %ServiceName%,,DokanFileSystem.Service", output.Inf);
        Assert.Contains("DefaultDestDir = 13", output.Inf);
        Assert.Contains("ServiceBinary  = %13%\\%DriverName%.sys", output.Inf);
        Assert.Contains("ServiceType    = 2", output.Inf);
        Assert.Contains("StartType      = 3", output.Inf);
        Assert.Contains("ServiceName        = \"AcmeFs2\"", output.Inf);
        Assert.Equal("acmefs2.inf", output.InfFileName);
        Assert.Equal("acmefs", output.RuntimeIdentity.DistributionId);
        Assert.Equal(profile.ProfileHash, output.RuntimeIdentity.ProfileHash);
    }

    [Fact]
    public void UpstreamProfilePreservesPublishedOperationalIdentity()
    {
        var profile = DistributionProfileLoader.Load(
            Path.Combine(RepositoryRoot, "profiles", "upstream.json"));
        var output = DistributionProfileGenerator.Render(profile);

        Assert.Equal("dokan2", profile.Family.BinaryBaseName);
        Assert.Equal("dokanctl", profile.Family.ControlBaseName);
        Assert.Equal("Dokan2", profile.Family.ServiceName);
        Assert.Equal("Dokan_2", profile.Derived.GlobalDeviceName);
        Assert.Equal("\\Device\\DokanFs2", profile.Derived.FileSystemDiskDeviceName);
        Assert.Equal("\\Device\\DokanCdFs2", profile.Derived.FileSystemCdDeviceName);
        Assert.Equal("\\Device\\DokanRedirector2", profile.Derived.RedirectorDeviceName);
        Assert.Equal("D6CC17C5-1734-4085-BCE7-964F1E9F5DE9", profile.Family.VolumeBaseGuid);
        Assert.Contains("DriverName         = \"dokan2\"", output.Inf);
        Assert.Equal("dokan2.inf", output.InfFileName);
    }

    [Fact]
    public void ReleasePackageIsImmutableAndHashesTheSelectedFamilyArtifacts()
    {
        var profile = DistributionProfileLoader.Load(
            ProfilePath("vendor.json"));
        var generated = DistributionProfileGenerator.Render(profile);
        using var temporary = new TemporaryDirectory();
        File.WriteAllText(Path.Combine(temporary.Path, "license.lgpl.txt"), "lgpl");
        File.WriteAllText(Path.Combine(temporary.Path, "license.mit.txt"), "mit");
        var artifacts = Path.Combine(temporary.Path, "artifacts");
        Directory.CreateDirectory(artifacts);
        var dll = Write(artifacts, "acmefs2.dll", "dll");
        var library = Write(artifacts, "acmefs2.lib", "lib");
        var driver = Write(artifacts, "acmefs2.sys", "sys");
        var inf = Write(artifacts, "acmefs2.inf", generated.Inf);
        var catalog = Write(artifacts, "acmefs2.cat", "cat");
        var control = Write(artifacts, "acmectl.exe", "control");
        var runtimeSymbols = Directory.CreateDirectory(Path.Combine(artifacts, "runtime-symbols")).FullName;
        var driverSymbols = Directory.CreateDirectory(Path.Combine(artifacts, "driver-symbols")).FullName;
        var runtimePdb = Write(runtimeSymbols, "acmefs2.pdb", "runtime symbols");
        var driverPdb = Write(driverSymbols, "acmefs2.pdb", "driver symbols");
        var controlPdb = Write(artifacts, "acmectl.pdb", "control symbols");
        var output = Path.Combine(temporary.Path, "package");

        var manifest = DistributionPackageBuilder.Create(
            profile,
            generated,
            new DistributionPackageInputs(
                "x64", new string('a', 40), output, dll, library, driver, inf, catalog, control,
                runtimePdb, driverPdb, controlPdb,
                temporary.Path));

        Assert.Equal(profile.ProfileHash, manifest.ProfileHash);
        Assert.Equal("runtimeDll", manifest.Files["runtime/acmefs2.dll"].Role);
        Assert.Equal("driverPdb", manifest.Files["symbols/acmefs2.sys.pdb"].Role);
        Assert.Equal(
            Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes("dll"))).ToLowerInvariant(),
            manifest.Files["runtime/acmefs2.dll"].Sha256);
        Assert.True(File.Exists(Path.Combine(output, "artifact-manifest.json")));
        Assert.Throws<DistributionProfileValidationException>(() => DistributionPackageBuilder.Create(
            profile,
            generated,
            new DistributionPackageInputs(
                "x64", new string('a', 40), output, dll, library, driver, inf, catalog, control,
                runtimePdb, driverPdb, controlPdb,
                temporary.Path)));
    }

    [Fact]
    public void ReleasePackageRejectsAnInfMutatedAfterProfileGeneration()
    {
        var profile = DistributionProfileLoader.Load(
            ProfilePath("vendor.json"));
        var generated = DistributionProfileGenerator.Render(profile);
        using var temporary = new TemporaryDirectory();
        File.WriteAllText(Path.Combine(temporary.Path, "license.lgpl.txt"), "lgpl");
        File.WriteAllText(Path.Combine(temporary.Path, "license.mit.txt"), "mit");
        var dll = Write(temporary.Path, "acmefs2.dll", "dll");
        var library = Write(temporary.Path, "acmefs2.lib", "lib");
        var driver = Write(temporary.Path, "acmefs2.sys", "sys");
        var inf = Write(temporary.Path, "acmefs2.inf", generated.Inf + "; mutation");
        var catalog = Write(temporary.Path, "acmefs2.cat", "cat");
        var control = Write(temporary.Path, "acmectl.exe", "control");
        var runtimeSymbols = Directory.CreateDirectory(Path.Combine(temporary.Path, "runtime-symbols")).FullName;
        var driverSymbols = Directory.CreateDirectory(Path.Combine(temporary.Path, "driver-symbols")).FullName;
        var runtimePdb = Write(runtimeSymbols, "acmefs2.pdb", "runtime symbols");
        var driverPdb = Write(driverSymbols, "acmefs2.pdb", "driver symbols");
        var controlPdb = Write(temporary.Path, "acmectl.pdb", "control symbols");

        var error = Assert.Throws<DistributionProfileValidationException>(() => DistributionPackageBuilder.Create(
            profile,
            generated,
            new DistributionPackageInputs(
                "x64", new string('b', 40), Path.Combine(temporary.Path, "package"), dll, library,
                driver, inf, catalog, control, runtimePdb, driverPdb, controlPdb, temporary.Path)));

        Assert.Contains("INF differs", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void VendorProfileCannotReuseOfficialOperationalIdentity()
    {
        var path = WriteProfileMutation(profile =>
            profile["family"]!["serviceName"] = "Dokan2");

        try
        {
            var error = Assert.Throws<DistributionProfileValidationException>(
                () => DistributionProfileLoader.Load(path));
            Assert.Contains("serviceName", error.Message);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void StableGuidsMustBeUniqueWithinAProfile()
    {
        var path = WriteProfileMutation(profile =>
            profile["family"]!["volumeBaseGuid"] = profile["family"]!["familyGuid"]!.GetValue<string>());

        try
        {
            var error = Assert.Throws<DistributionProfileValidationException>(
                () => DistributionProfileLoader.Load(path));
            Assert.Contains("GUID", error.Message);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void DriverDateMustUseTheInfDriverVerFormat()
    {
        var path = WriteProfileMutation(profile =>
            profile["release"]!["driverDate"] = "2026-07-23");

        try
        {
            var error = Assert.Throws<DistributionProfileValidationException>(
                () => DistributionProfileLoader.Load(path));
            Assert.Contains("driverDate", error.Message);
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static string WriteProfileMutation(Action<System.Text.Json.Nodes.JsonObject> mutate)
    {
        var source = ProfilePath("vendor.json");
        var profile = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(source))!.AsObject();
        mutate(profile);
        var path = Path.Combine(Path.GetTempPath(), $"dokany-profile-{Guid.NewGuid():N}.json");
        File.WriteAllText(path, profile.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        return path;
    }

    private static string ProfilePath(string fileName) => fileName == "upstream.json"
        ? Path.Combine(RepositoryRoot, "profiles", fileName)
        : Path.Combine(RepositoryRoot, "tools", "DistributionProfile.Tests", "Fixtures", fileName);

    private static string Write(string directory, string name, string content)
    {
        var path = Path.Combine(directory, name);
        File.WriteAllText(path, content);
        return path;
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public TemporaryDirectory()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"dokany-package-{Guid.NewGuid():N}");
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public void Dispose()
        {
            Directory.Delete(Path, recursive: true);
        }
    }
}
