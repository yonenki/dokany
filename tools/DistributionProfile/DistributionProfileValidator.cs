using System.Text.RegularExpressions;
using System.Diagnostics.CodeAnalysis;
using System.Globalization;

namespace Dokany.DistributionProfile;

internal static partial class DistributionProfileValidator
{
    private static readonly HashSet<string> OfficialOperationalIdentities =
        new(StringComparer.OrdinalIgnoreCase)
        {
            "dokan2",
            "dokannp2",
            "Dokan",
            "Dokan2",
        };

    public static void Validate(DistributionProfile profile)
    {
        if (profile.SchemaVersion != 1)
        {
            Fail("schemaVersion must be 1.");
        }

        RequireMatch(DistributionIdPattern(), profile.DistributionId, "distributionId");
        RequireText(profile.DisplayName, "displayName", 128);
        RequireText(profile.ProviderName, "providerName", 64);
        RequireText(profile.CompanyName, "companyName", 128);

        if (profile.ApiMajor is < 1 or > 99)
        {
            Fail("apiMajor must be between 1 and 99.");
        }

        if (!Version.TryParse(profile.Release.ProductVersion, out var productVersion) ||
            productVersion.Revision < 0 ||
            new[] { productVersion.Major, productVersion.Minor, productVersion.Build, productVersion.Revision }
                .Any(component => component is < 0 or > ushort.MaxValue))
        {
            Fail("release.productVersion must contain four 16-bit numeric components.");
        }

        if (productVersion.Major > 9 || productVersion.Minor > 9 || productVersion.Build > 9)
        {
            Fail("The first three productVersion components must fit Dokan's decimal API version encoding.");
        }

        if (!DateOnly.TryParseExact(
                profile.Release.DriverDate,
                "MM/dd/yyyy",
                CultureInfo.InvariantCulture,
                DateTimeStyles.None,
                out _))
        {
            Fail("release.driverDate must use the MM/dd/yyyy INF DriverVer format.");
        }

        if (profile.Release.ProtocolAbi <= 0)
        {
            Fail("release.protocolAbi must be positive.");
        }

        RequireMatch(BinaryNamePattern(), profile.Family.BinaryBaseName, "family.binaryBaseName");
        RequireMatch(BinaryNamePattern(), profile.Family.ControlBaseName, "family.controlBaseName");
        RequireMatch(WindowsIdentityPattern(), profile.Family.ServiceName, "family.serviceName");
        RequireMatch(WindowsIdentityPattern(), profile.Family.DevicePrefix, "family.devicePrefix");
        RequireMatch(WindowsIdentityPattern(), profile.Family.EventLogSource, "family.eventLogSource");
        RequireText(profile.Family.VolumeLabel, "family.volumeLabel", 32);

        var apiSuffix = profile.ApiMajor.ToString(System.Globalization.CultureInfo.InvariantCulture);
        if (!profile.Family.BinaryBaseName.EndsWith(apiSuffix, StringComparison.Ordinal))
        {
            Fail("family.binaryBaseName must end with apiMajor.");
        }

        RequireMatch(WindowsIdentityPattern(), profile.Family.NetworkProvider.Name, "family.networkProvider.name");
        RequireMatch(BinaryNamePattern(), profile.Family.NetworkProvider.DllBaseName, "family.networkProvider.dllBaseName");

        var guids = new List<(string Name, string Value)>
        {
            ("family.familyGuid", profile.Family.FamilyGuid),
            ("family.volumeBaseGuid", profile.Family.VolumeBaseGuid),
        };
        guids.AddRange(profile.Installer.EnumerateGuids().Select(pair => ($"installer.{pair.Name}", pair.Value)));
        ValidateGuids(guids);

        if (!profile.DistributionId.Equals("dokany", StringComparison.OrdinalIgnoreCase))
        {
            RejectOfficialIdentity(profile.Family.BinaryBaseName, "family.binaryBaseName");
            RejectOfficialIdentity(profile.Family.ControlBaseName, "family.controlBaseName");
            RejectOfficialIdentity(profile.Family.ServiceName, "family.serviceName");
            RejectOfficialIdentity(profile.Family.DevicePrefix, "family.devicePrefix");
            RejectOfficialIdentity(profile.Family.EventLogSource, "family.eventLogSource");
            RejectOfficialIdentity(profile.ProviderName, "providerName");
            RejectOfficialIdentity(profile.Family.NetworkProvider.Name, "family.networkProvider.name");
            RejectOfficialIdentity(profile.Family.NetworkProvider.DllBaseName, "family.networkProvider.dllBaseName");
        }

        var longestDerivedDeviceName = $"\\DosDevices\\Global\\{profile.Family.DevicePrefix}Redirector{apiSuffix}";
        if (longestDerivedDeviceName.Length >= 64)
        {
            Fail("Derived device names must fit the 64 WCHAR driver protocol fields.");
        }
    }

    private static void ValidateGuids(IEnumerable<(string Name, string Value)> values)
    {
        var seen = new Dictionary<Guid, string>();
        foreach (var (name, value) in values)
        {
            if (!Guid.TryParseExact(value, "D", out var guid) || guid == Guid.Empty)
            {
                Fail($"{name} must be a non-empty GUID in D format.");
            }

            if (seen.TryGetValue(guid, out var existingName))
            {
                Fail($"GUID values must be unique: {name} reuses {existingName}.");
            }

            seen.Add(guid, name);
        }
    }

    private static void RejectOfficialIdentity(string value, string fieldName)
    {
        if (OfficialOperationalIdentities.Contains(value))
        {
            Fail($"{fieldName} cannot reuse official Dokany operational identity '{value}'.");
        }
    }

    private static void RequireText(string? value, string fieldName, int maxLength)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > maxLength || value.Any(char.IsControl))
        {
            Fail($"{fieldName} must be non-empty, control-character-free, and at most {maxLength} characters.");
        }
    }

    private static void RequireMatch(Regex pattern, string? value, string fieldName)
    {
        if (value is null || !pattern.IsMatch(value))
        {
            Fail($"{fieldName} has an invalid value.");
        }
    }

    [DoesNotReturn]
    private static void Fail(string message) => throw new DistributionProfileValidationException(message);

    [GeneratedRegex("^[a-z][a-z0-9-]{1,31}$", RegexOptions.CultureInvariant)]
    private static partial Regex DistributionIdPattern();

    [GeneratedRegex("^[a-z][a-z0-9]{1,31}$", RegexOptions.CultureInvariant)]
    private static partial Regex BinaryNamePattern();

    [GeneratedRegex("^[A-Za-z][A-Za-z0-9]{1,62}$", RegexOptions.CultureInvariant)]
    private static partial Regex WindowsIdentityPattern();
}
