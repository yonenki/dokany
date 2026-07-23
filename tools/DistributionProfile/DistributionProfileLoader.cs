using System.Security.Cryptography;
using System.Text.Json;

namespace Dokany.DistributionProfile;

public static class DistributionProfileLoader
{
    private static readonly JsonSerializerOptions InputOptions = new()
    {
        AllowTrailingCommas = false,
        PropertyNameCaseInsensitive = false,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        ReadCommentHandling = JsonCommentHandling.Disallow,
        UnmappedMemberHandling = System.Text.Json.Serialization.JsonUnmappedMemberHandling.Disallow,
    };

    private static readonly JsonSerializerOptions CanonicalOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false,
    };

    public static DistributionProfile Load(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);

        DistributionProfile profile;
        try
        {
            profile = JsonSerializer.Deserialize<DistributionProfile>(
                File.ReadAllText(path), InputOptions)
                ?? throw new DistributionProfileValidationException("Profile document cannot be null.");
        }
        catch (JsonException exception)
        {
            throw new DistributionProfileValidationException(
                $"Profile JSON is invalid: {exception.Message}", exception);
        }

        DistributionProfileValidator.Validate(profile);
        var canonicalBytes = JsonSerializer.SerializeToUtf8Bytes(profile, CanonicalOptions);
        var hash = Convert.ToHexString(SHA256.HashData(canonicalBytes)).ToLowerInvariant();
        var apiMajor = profile.ApiMajor.ToString(System.Globalization.CultureInfo.InvariantCulture);
        var devicePrefix = profile.Family.DevicePrefix;

        return profile with
        {
            ProfileHash = hash,
            Derived = new DerivedIdentity(
                $"{devicePrefix}_{apiMajor}",
                $"\\Device\\{devicePrefix}_{apiMajor}",
                $"\\DosDevices\\Global\\{devicePrefix}_{apiMajor}",
                $"\\Device\\{devicePrefix}Fs{apiMajor}",
                $"\\Device\\{devicePrefix}CdFs{apiMajor}",
                $"\\Device\\{devicePrefix}Redirector{apiMajor}",
                $"\\DosDevices\\Global\\{devicePrefix}Redirector{apiMajor}",
                $"%SystemRoot%\\System32\\drivers\\{profile.Family.BinaryBaseName}.sys")
        };
    }
}
