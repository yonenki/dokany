using System.Text.RegularExpressions;

namespace Dokany.DistributionProfile;

public sealed partial record SourceBuildIdentity
{
    private SourceBuildIdentity(string value)
    {
        Value = value;
    }

    public string Value { get; }

    public static SourceBuildIdentity Parse(string value)
    {
        if (value is null || !FullGitObjectId().IsMatch(value))
        {
            throw new DistributionProfileValidationException(
                "Source build must be a full 40-character Git object ID.");
        }

        return new SourceBuildIdentity(value.ToLowerInvariant());
    }

    public override string ToString() => Value;

    [GeneratedRegex("^[0-9a-fA-F]{40}$", RegexOptions.CultureInvariant)]
    private static partial Regex FullGitObjectId();
}
