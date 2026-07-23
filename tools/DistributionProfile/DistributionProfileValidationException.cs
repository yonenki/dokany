namespace Dokany.DistributionProfile;

public sealed class DistributionProfileValidationException : Exception
{
    public DistributionProfileValidationException(string message)
        : base(message)
    {
    }

    public DistributionProfileValidationException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
