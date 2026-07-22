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
    [switch]$RequireSignatures
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $repositoryRoot
try {
    $profilePath = (Resolve-Path -LiteralPath $DistributionProfile).Path
    $profile = (& dotnet run --project .\tools\DistributionProfile\DistributionProfile.csproj -- validate $profilePath) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Distribution profile validation failed with exit code $LASTEXITCODE." }

    $generatedRoot = Join-Path $repositoryRoot "BuildOutput\profiles\$($profile.distributionId)-$($profile.profileHash)"
    & dotnet run --project .\tools\DistributionProfile\DistributionProfile.csproj -- generate $profilePath $generatedRoot | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Distribution profile generation failed with exit code $LASTEXITCODE." }
    $runtimeIdentity = Get-Content -Raw -LiteralPath (Join-Path $generatedRoot 'runtime-identity.json') | ConvertFrom-Json
    $binaryBaseName = $runtimeIdentity.family.binaryBaseName
    $controlBaseName = $profile.controlBaseName
    $platformDirectory = if ($Architecture -eq 'arm64') { 'ARM64' } else { 'x64' }

    $headCommit = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve the source commit.' }
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
    if ([string]::IsNullOrWhiteSpace($RuntimeDll)) {
        $RuntimeDll = Join-Path $repositoryRoot "$platformDirectory\$Configuration\$binaryBaseName.dll"
    }
    if ([string]::IsNullOrWhiteSpace($ImportLibrary)) {
        $ImportLibrary = Join-Path $repositoryRoot "$platformDirectory\$Configuration\$binaryBaseName.lib"
    }
    if ([string]::IsNullOrWhiteSpace($Driver)) {
        $Driver = Join-Path $repositoryRoot "$platformDirectory\$Configuration\Driver\sys\$binaryBaseName.sys"
    }
    if ([string]::IsNullOrWhiteSpace($Inf)) {
        $Inf = Join-Path $generatedRoot "$binaryBaseName.inf"
    }
    if ([string]::IsNullOrWhiteSpace($Catalog)) {
        $Catalog = Join-Path $repositoryRoot "$platformDirectory\$Configuration\Driver\sys\$binaryBaseName.cat"
    }
    if ([string]::IsNullOrWhiteSpace($ControlTool)) {
        $ControlTool = Join-Path $repositoryRoot "$platformDirectory\$Configuration\$controlBaseName.exe"
    }

    if ($RequireSignatures) {
        foreach ($path in @($RuntimeDll, $Driver, $Catalog, $ControlTool)) {
            $signature = Get-AuthenticodeSignature -LiteralPath $path
            if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
                throw "Required Authenticode signature is not valid for ${path}: $($signature.Status)"
            }
        }
    }

    & dotnet run --project .\tools\DistributionProfile\DistributionProfile.csproj -- package `
        $profilePath $Architecture $SourceCommit $OutputDirectory $RuntimeDll $ImportLibrary `
        $Driver $Inf $Catalog $ControlTool
    if ($LASTEXITCODE -ne 0) { throw "Distribution package creation failed with exit code $LASTEXITCODE." }
}
finally {
    Pop-Location
}
