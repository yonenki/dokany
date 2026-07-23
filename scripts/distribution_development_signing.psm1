Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'distribution_artifacts.psm1')

function New-DistributionDevelopmentSigningPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Artifacts,
        [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$Architecture,
        [string]$Inf2CatOs = ''
    )

    if ([string]::IsNullOrWhiteSpace($Inf2CatOs)) {
        $Inf2CatOs = if ($Architecture -eq 'arm64') {
            '10_ARM64,10_NI_ARM64'
        } else {
            '10_X64,10_NI_X64'
        }
    }

    return [pscustomobject]@{
        BinaryBaseName = [string]$Context.BinaryBaseName
        EmbeddedSignatureTargets = @(
            [string]$Artifacts.Driver,
            [string]$Artifacts.RuntimeDll,
            [string]$Artifacts.ControlTool
        )
        CatalogInputs = @(
            [string]$Artifacts.Inf,
            [string]$Artifacts.Driver
        )
        Catalog = [string]$Artifacts.Catalog
        Inf2CatOs = $Inf2CatOs
    }
}

function Resolve-WindowsKitTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ExplicitPath = '',
        [string[]]$PreferredArchitectures = @('x64', 'x86')
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolved = (Resolve-Path -LiteralPath $ExplicitPath).Path
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw [System.IO.FileNotFoundException]::new("Windows Kit tool is not a file: $resolved", $resolved)
        }
        return $resolved
    }

    $kitRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (-not (Test-Path -LiteralPath $kitRoot -PathType Container)) {
        throw [System.IO.DirectoryNotFoundException]::new("Windows Kit bin directory does not exist: $kitRoot")
    }

    $candidates = @()
    foreach ($versionDirectory in Get-ChildItem -LiteralPath $kitRoot -Directory) {
        $parsedVersion = $null
        if (-not [version]::TryParse($versionDirectory.Name, [ref]$parsedVersion)) { continue }
        for ($index = 0; $index -lt $PreferredArchitectures.Count; $index++) {
            $candidate = Join-Path $versionDirectory.FullName "$($PreferredArchitectures[$index])\$Name"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $candidates += [pscustomobject]@{
                    Path = $candidate
                    Version = $parsedVersion
                    ArchitectureRank = $index
                }
            }
        }
    }
    $selected = $candidates |
        Sort-Object -Property @{ Expression = 'Version'; Descending = $true }, @{ Expression = 'ArchitectureRank'; Ascending = $true } |
        Select-Object -First 1
    if ($null -eq $selected) {
        throw [System.IO.FileNotFoundException]::new("Windows Kit tool was not found: $Name")
    }
    return [string]$selected.Path
}

function Invoke-CheckedNativeTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    & $Path @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new("$Operation failed with exit code $LASTEXITCODE.")
    }
}

function Get-DevelopmentSigningCertificate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Thumbprint,
        [Parameter(Mandatory = $true)][ValidateSet('CurrentUser', 'LocalMachine')][string]$StoreLocation
    )

    $normalizedThumbprint = $Thumbprint.Replace(' ', '').ToUpperInvariant()
    if ($normalizedThumbprint -notmatch '^[0-9A-F]{40}$') {
        throw [System.ArgumentException]::new('Certificate thumbprint must contain exactly 40 hexadecimal characters.', 'Thumbprint')
    }
    $certificatePath = "Cert:\$StoreLocation\My\$normalizedThumbprint"
    $certificate = Get-Item -LiteralPath $certificatePath -ErrorAction SilentlyContinue
    if ($null -eq $certificate) {
        throw [System.Security.Cryptography.CryptographicException]::new(
            "Signing certificate was not found: $certificatePath")
    }
    if (-not $certificate.HasPrivateKey) {
        throw [System.Security.Cryptography.CryptographicException]::new(
            'Signing certificate does not have an accessible private key.')
    }
    $now = [DateTime]::Now
    if ($now -lt $certificate.NotBefore -or $now -ge $certificate.NotAfter) {
        throw [System.Security.Cryptography.CryptographicException]::new(
            'Signing certificate is not currently valid.')
    }

    $hasCodeSigningUsage = $false
    foreach ($extension in $certificate.Extensions) {
        if ($extension.Oid.Value -ne '2.5.29.37') { continue }
        $enhancedUsage = [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$extension
        foreach ($usage in $enhancedUsage.EnhancedKeyUsages) {
            if ($usage.Value -eq '1.3.6.1.5.5.7.3.3') { $hasCodeSigningUsage = $true }
        }
    }
    if (-not $hasCodeSigningUsage) {
        throw [System.Security.Cryptography.CryptographicException]::new(
            'Signing certificate does not permit code signing.')
    }
    return $certificate
}

function Assert-ExistingSigningInput {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("Signing input does not exist: $Path", $Path)
    }
}

function Assert-AuthenticodeSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedThumbprint
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw [System.Security.Cryptography.CryptographicException]::new(
            "Authenticode signature is not valid for ${Path}: $($signature.Status)")
    }
    if ($null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -ine $ExpectedThumbprint) {
        throw [System.Security.Cryptography.CryptographicException]::new(
            "Authenticode signer does not match the requested certificate: $Path")
    }
}

function Assert-DistributionCatalogMembership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Catalog,
        [Parameter(Mandatory = $true)][string[]]$Inputs,
        [string]$SignTool = ''
    )

    Assert-ExistingSigningInput -Path $Catalog
    if ($Inputs.Count -eq 0) {
        throw [System.ArgumentException]::new(
            'At least one catalog input must be supplied.', 'Inputs')
    }
    $resolvedSignTool = Resolve-WindowsKitTool -Name 'signtool.exe' -ExplicitPath $SignTool
    foreach ($inputPath in $Inputs) {
        Assert-ExistingSigningInput -Path $inputPath
        Invoke-CheckedNativeTool `
            -Path $resolvedSignTool `
            -Arguments @('verify', '/v', '/pa', '/c', $Catalog, $inputPath) `
            -Operation "Verifying catalog membership for $inputPath"
    }
}

function Invoke-DistributionDevelopmentSigning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DistributionProfile,
        [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$Architecture,
        [string]$Configuration = 'Release',
        [Parameter(Mandatory = $true)][string]$CertificateThumbprint,
        [ValidateSet('CurrentUser', 'LocalMachine')][string]$CertificateStoreLocation = 'LocalMachine',
        [string]$SignTool = '',
        [string]$Inf2Cat = '',
        [string]$Inf2CatOs = '',
        [string]$TimestampUrl = '',
        [string]$RuntimeDll = '',
        [string]$Driver = '',
        [string]$Inf = '',
        [string]$Catalog = '',
        [string]$ControlTool = ''
    )

    $context = Get-DistributionBuildContext -DistributionProfile $DistributionProfile
    $artifacts = Resolve-DistributionArtifactPaths `
        -Context $context `
        -Architecture $Architecture `
        -Configuration $Configuration `
        -RuntimeDll $RuntimeDll `
        -Driver $Driver `
        -Inf $Inf `
        -Catalog $Catalog `
        -ControlTool $ControlTool
    $plan = New-DistributionDevelopmentSigningPlan `
        -Context $context `
        -Artifacts $artifacts `
        -Architecture $Architecture `
        -Inf2CatOs $Inf2CatOs

    foreach ($path in $plan.EmbeddedSignatureTargets + $plan.CatalogInputs) {
        Assert-ExistingSigningInput -Path $path
    }
    $certificate = Get-DevelopmentSigningCertificate `
        -Thumbprint $CertificateThumbprint `
        -StoreLocation $CertificateStoreLocation
    $normalizedThumbprint = $certificate.Thumbprint.ToUpperInvariant()
    $resolvedSignTool = Resolve-WindowsKitTool -Name 'signtool.exe' -ExplicitPath $SignTool
    $resolvedInf2Cat = Resolve-WindowsKitTool `
        -Name 'inf2cat.exe' `
        -ExplicitPath $Inf2Cat `
        -PreferredArchitectures @('x86', 'x64')

    $certificateArguments = @('/sha1', $normalizedThumbprint, '/s', 'My')
    if ($CertificateStoreLocation -eq 'LocalMachine') { $certificateArguments += '/sm' }
    $timestampArguments = @()
    if (-not [string]::IsNullOrWhiteSpace($TimestampUrl)) {
        $timestampArguments = @('/tr', $TimestampUrl, '/td', 'SHA256')
    }

    foreach ($target in $plan.EmbeddedSignatureTargets) {
        $arguments = @('sign', '/v', '/fd', 'SHA256') + $certificateArguments + $timestampArguments + @($target)
        Invoke-CheckedNativeTool -Path $resolvedSignTool -Arguments $arguments -Operation "Signing $target"
    }

    $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $stagingRoot = Join-Path $temporaryRoot ("dokany-signing-" + [Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($stagingRoot) | Out-Null
    try {
        $stagedInf = Join-Path $stagingRoot "$($plan.BinaryBaseName).inf"
        $stagedDriver = Join-Path $stagingRoot "$($plan.BinaryBaseName).sys"
        Copy-Item -LiteralPath $artifacts.Inf -Destination $stagedInf
        Copy-Item -LiteralPath $artifacts.Driver -Destination $stagedDriver

        Invoke-CheckedNativeTool `
            -Path $resolvedInf2Cat `
            -Arguments @("/driver:$stagingRoot", "/os:$($plan.Inf2CatOs)", '/uselocaltime', '/verbose') `
            -Operation 'Generating the driver catalog'

        $generatedCatalog = Join-Path $stagingRoot "$($plan.BinaryBaseName).cat"
        Assert-ExistingSigningInput -Path $generatedCatalog
        $catalogParent = Split-Path -Parent $plan.Catalog
        if (-not (Test-Path -LiteralPath $catalogParent -PathType Container)) {
            throw [System.IO.DirectoryNotFoundException]::new(
                "Catalog output directory does not exist: $catalogParent")
        }
        Copy-Item -LiteralPath $generatedCatalog -Destination $plan.Catalog -Force

        $catalogSignArguments = @('sign', '/v', '/fd', 'SHA256') +
            $certificateArguments + $timestampArguments + @($plan.Catalog)
        Invoke-CheckedNativeTool `
            -Path $resolvedSignTool `
            -Arguments $catalogSignArguments `
            -Operation "Signing $($plan.Catalog)"

        foreach ($target in $plan.EmbeddedSignatureTargets + @($plan.Catalog)) {
            Assert-AuthenticodeSignature -Path $target -ExpectedThumbprint $normalizedThumbprint
            Invoke-CheckedNativeTool `
                -Path $resolvedSignTool `
                -Arguments @('verify', '/v', '/pa', $target) `
                -Operation "Verifying $target"
        }
        Assert-DistributionCatalogMembership `
            -Catalog $plan.Catalog `
            -Inputs @($stagedInf, $stagedDriver) `
            -SignTool $resolvedSignTool
    }
    finally {
        $resolvedStagingRoot = [System.IO.Path]::GetFullPath($stagingRoot)
        if ($resolvedStagingRoot.StartsWith($temporaryRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
            $resolvedStagingRoot -ne $temporaryRoot -and
            (Test-Path -LiteralPath $resolvedStagingRoot)) {
            Remove-Item -LiteralPath $resolvedStagingRoot -Recurse -Force
        }
    }

    return [pscustomobject]@{
        DistributionId = [string]$context.Profile.distributionId
        ProfileHash = [string]$context.Profile.profileHash
        Architecture = $Architecture
        CertificateThumbprint = $normalizedThumbprint
        Artifacts = $artifacts
    }
}

Export-ModuleMember -Function New-DistributionDevelopmentSigningPlan, Invoke-DistributionDevelopmentSigning, Assert-DistributionCatalogMembership
