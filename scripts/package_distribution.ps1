param (
    [Parameter(Mandatory = $true)]
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture,
    [Parameter(Mandatory = $true)]
    [string]$DistributionProfile,
    [string]$Configuration = 'Release',
    [string]$SourceCommit = '',
    [string]$OutputDirectory = '',
    [string]$RuntimeDll = '',
    [string]$ImportLibrary = '',
    [string]$Driver = '',
    [string]$Inf = '',
    [string]$Catalog = '',
    [string]$ControlTool = '',
    [string]$RuntimePdb = '',
    [string]$DriverPdb = '',
    [string]$ControlPdb = '',
    [string]$SignTool = '',
    [switch]$RequireSignatures
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $PSScriptRoot 'distribution_artifacts.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'distribution_development_signing.psm1') -Force
Push-Location $repositoryRoot
try {
    $context = Get-DistributionBuildContext -DistributionProfile $DistributionProfile
    $profilePath = $context.ProfilePath
    $profile = $context.Profile

    $headCommit = [string]$context.SourceCommit
    if ([string]::IsNullOrWhiteSpace($SourceCommit)) {
        $SourceCommit = $headCommit
    } elseif ($SourceCommit -ne $headCommit) {
        throw "Source commit $SourceCommit does not match checked out HEAD $headCommit."
    }
    $trackedChanges = & git status --porcelain --untracked-files=no
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect the source worktree.' }
    if ($trackedChanges) {
        throw 'Refusing to package artifacts from a worktree with tracked changes.'
    }
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $OutputDirectory = Join-Path $repositoryRoot "BuildOutput\packages\$($profile.distributionId)-$($profile.profileHash)\$Architecture"
    }
    $artifacts = Resolve-DistributionArtifactPaths `
        -Context $context `
        -Architecture $Architecture `
        -Configuration $Configuration `
        -RuntimeDll $RuntimeDll `
        -ImportLibrary $ImportLibrary `
        -Driver $Driver `
        -Inf $Inf `
        -Catalog $Catalog `
        -ControlTool $ControlTool `
        -RuntimePdb $RuntimePdb `
        -DriverPdb $DriverPdb `
        -ControlPdb $ControlPdb
    $RuntimeDll = $artifacts.RuntimeDll
    $ImportLibrary = $artifacts.ImportLibrary
    $Driver = $artifacts.Driver
    $Inf = $artifacts.Inf
    $Catalog = $artifacts.Catalog
    $ControlTool = $artifacts.ControlTool
    $RuntimePdb = $artifacts.RuntimePdb
    $DriverPdb = $artifacts.DriverPdb
    $ControlPdb = $artifacts.ControlPdb

    if ($RequireSignatures) {
        foreach ($path in @($RuntimeDll, $Driver, $Catalog, $ControlTool)) {
            $signature = Get-AuthenticodeSignature -LiteralPath $path
            if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
                throw "Required Authenticode signature is not valid for ${path}: $($signature.Status)"
            }
        }
        Assert-DistributionCatalogMembership `
            -Catalog $Catalog `
            -Inputs @($Inf, $Driver) `
            -SignTool $SignTool
    }

    & dotnet run --project .\tools\DistributionProfile\DistributionProfile.csproj -- package `
        $profilePath $Architecture $SourceCommit $OutputDirectory $RuntimeDll $ImportLibrary `
        $Driver $Inf $Catalog $ControlTool $RuntimePdb $DriverPdb $ControlPdb
    if ($LASTEXITCODE -ne 0) { throw "Distribution package creation failed with exit code $LASTEXITCODE." }
}
finally {
    Pop-Location
}
