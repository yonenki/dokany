using System.Text.Json.Serialization;

namespace Dokany.DistributionProfile;

public sealed record DistributionProfile
{
    public required int SchemaVersion { get; init; }
    public required string DistributionId { get; init; }
    public required string DisplayName { get; init; }
    public required string ProviderName { get; init; }
    public required string CompanyName { get; init; }
    public required int ApiMajor { get; init; }
    public required ReleaseIdentity Release { get; init; }
    public required FamilyIdentity Family { get; init; }
    public required InstallerIdentity Installer { get; init; }

    [JsonIgnore]
    public string ProfileHash { get; init; } = string.Empty;

    [JsonIgnore]
    public DerivedIdentity Derived { get; init; } = DerivedIdentity.Empty;
}

public sealed record ReleaseIdentity
{
    public required string ProductVersion { get; init; }
    public required string DriverDate { get; init; }
    public required int ProtocolAbi { get; init; }
}

public sealed record FamilyIdentity
{
    public required string BinaryBaseName { get; init; }
    public required string ControlBaseName { get; init; }
    public required string ServiceName { get; init; }
    public required string DevicePrefix { get; init; }
    public required string EventLogSource { get; init; }
    public required string VolumeLabel { get; init; }
    public required string FamilyGuid { get; init; }
    public required string VolumeBaseGuid { get; init; }
    public required NetworkProviderIdentity NetworkProvider { get; init; }
}

public sealed record NetworkProviderIdentity
{
    public required bool Enabled { get; init; }
    public required string Name { get; init; }
    public required string DllBaseName { get; init; }
}

public sealed record InstallerIdentity
{
    public required string ProductCodeX64 { get; init; }
    public required string UpgradeCodeX64 { get; init; }
    public required string ProductCodeX86 { get; init; }
    public required string UpgradeCodeX86 { get; init; }
    public required string ProductCodeArm64 { get; init; }
    public required string UpgradeCodeArm64 { get; init; }
    public required string ProviderKey { get; init; }
    public required string BundleUpgradeCode { get; init; }

    public IEnumerable<(string Name, string Value)> EnumerateGuids()
    {
        yield return (nameof(ProductCodeX64), ProductCodeX64);
        yield return (nameof(UpgradeCodeX64), UpgradeCodeX64);
        yield return (nameof(ProductCodeX86), ProductCodeX86);
        yield return (nameof(UpgradeCodeX86), UpgradeCodeX86);
        yield return (nameof(ProductCodeArm64), ProductCodeArm64);
        yield return (nameof(UpgradeCodeArm64), UpgradeCodeArm64);
        yield return (nameof(ProviderKey), ProviderKey);
        yield return (nameof(BundleUpgradeCode), BundleUpgradeCode);
    }
}

public sealed record DerivedIdentity(
    string GlobalDeviceName,
    string GlobalDeviceNtPath,
    string GlobalSymbolicLinkName,
    string FileSystemDiskDeviceName,
    string FileSystemCdDeviceName,
    string RedirectorDeviceName,
    string RedirectorSymbolicLinkName,
    string DriverSystemPath)
{
    public static DerivedIdentity Empty { get; } = new("", "", "", "", "", "", "", "");
}

public sealed record RuntimeIdentityManifest(
    int SchemaVersion,
    string DistributionId,
    string ProfileHash,
    string ProductVersion,
    int ProtocolAbi,
    RuntimeFamilyManifest Family);

public sealed record RuntimeFamilyManifest(
    string BinaryBaseName,
    string ServiceName,
    string GlobalDeviceName,
    string FamilyGuid,
    string VolumeBaseGuid);

public sealed record GeneratedDistributionProfile(
    SourceBuildIdentity SourceBuild,
    string Header,
    string RustConstants,
    string MsBuildProps,
    string Inf,
    string InfFileName,
    string VersionXml,
    RuntimeIdentityManifest RuntimeIdentity);
