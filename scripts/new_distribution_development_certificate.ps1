#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Subject,
    [ValidateRange(1, 24)]
    [int]$ValidityMonths = 6,
    [string]$CertificateOutputPath = '',
    [Parameter(Mandatory = $true)]
    [switch]$TrustForTestMachine
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $TrustForTestMachine) {
    throw [System.ArgumentException]::new(
        'TrustForTestMachine must be explicitly supplied for development certificate creation.',
        'TrustForTestMachine')
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw [System.UnauthorizedAccessException]::new(
        'Development certificate creation and LocalMachine trust require an elevated PowerShell process.')
}

$certificate = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject $Subject `
    -CertStoreLocation 'Cert:\LocalMachine\My' `
    -KeyAlgorithm RSA `
    -KeyLength 3072 `
    -HashAlgorithm SHA256 `
    -KeyExportPolicy NonExportable `
    -NotAfter ([DateTime]::Now.AddMonths($ValidityMonths))

if ($null -eq $certificate -or -not $certificate.HasPrivateKey) {
    throw [System.Security.Cryptography.CryptographicException]::new(
        'The development signing certificate was not created with an accessible private key.')
}

if ([string]::IsNullOrWhiteSpace($CertificateOutputPath)) {
    $repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $CertificateOutputPath = Join-Path $repositoryRoot "BuildOutput\development-signing\$($certificate.Thumbprint).cer"
}
$CertificateOutputPath = [System.IO.Path]::GetFullPath($CertificateOutputPath)
$certificateOutputDirectory = Split-Path -Parent $CertificateOutputPath
[System.IO.Directory]::CreateDirectory($certificateOutputDirectory) | Out-Null

Export-Certificate -Cert $certificate -FilePath $CertificateOutputPath -Force | Out-Null
Import-Certificate -FilePath $CertificateOutputPath -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
Import-Certificate -FilePath $CertificateOutputPath -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' | Out-Null

foreach ($trustedPath in @(
    "Cert:\LocalMachine\Root\$($certificate.Thumbprint)",
    "Cert:\LocalMachine\TrustedPublisher\$($certificate.Thumbprint)"
)) {
    if (-not (Test-Path -LiteralPath $trustedPath)) {
        throw [System.Security.Cryptography.CryptographicException]::new(
            "Development certificate trust installation failed: $trustedPath")
    }
}

[pscustomobject]@{
    Purpose = 'development-test-signing'
    Subject = $certificate.Subject
    Thumbprint = $certificate.Thumbprint.ToUpperInvariant()
    CertificatePath = $CertificateOutputPath
    NotAfter = $certificate.NotAfter.ToUniversalTime().ToString('O')
    PrivateKeyExportable = $false
    TrustedStores = @('LocalMachine\Root', 'LocalMachine\TrustedPublisher')
} | ConvertTo-Json -Depth 3
