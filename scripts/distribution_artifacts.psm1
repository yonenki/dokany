Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-DistributionProfileTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    Push-Location $RepositoryRoot
    try {
        $output = & dotnet run --project .\tools\DistributionProfile\DistributionProfile.csproj -- @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                "Distribution profile tool failed with exit code $LASTEXITCODE.")
        }
        return $output
    }
    finally {
        Pop-Location
    }
}

function Get-DistributionBuildContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DistributionProfile
    )

    $repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $profilePath = (Resolve-Path -LiteralPath $DistributionProfile).Path
    $profileJson = Invoke-DistributionProfileTool `
        -RepositoryRoot $repositoryRoot `
        -Arguments @('validate', $profilePath)
    try {
        $profile = $profileJson | ConvertFrom-Json
    }
    catch {
        throw [System.InvalidOperationException]::new(
            'Distribution profile validation did not return valid JSON.', $_.Exception)
    }

    $generatedRoot = Join-Path $repositoryRoot "BuildOutput\profiles\$($profile.distributionId)-$($profile.profileHash)"
    Invoke-DistributionProfileTool `
        -RepositoryRoot $repositoryRoot `
        -Arguments @('generate', $profilePath, $generatedRoot) | Out-Null

    $runtimeIdentityPath = Join-Path $generatedRoot 'runtime-identity.json'
    if (-not (Test-Path -LiteralPath $runtimeIdentityPath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new(
            'Distribution profile generation did not produce runtime-identity.json.',
            $runtimeIdentityPath)
    }
    try {
        $runtimeIdentity = Get-Content -Raw -LiteralPath $runtimeIdentityPath | ConvertFrom-Json
    }
    catch {
        throw [System.InvalidOperationException]::new(
            'Generated runtime identity is not valid JSON.', $_.Exception)
    }

    return [pscustomobject]@{
        RepositoryRoot = $repositoryRoot
        ProfilePath = $profilePath
        Profile = $profile
        GeneratedRoot = $generatedRoot
        RuntimeIdentity = $runtimeIdentity
        BinaryBaseName = [string]$runtimeIdentity.family.binaryBaseName
        ControlBaseName = [string]$profile.controlBaseName
    }
}

function Resolve-DistributionArtifactPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$Configuration,
        [string]$RuntimeDll = '',
        [string]$ImportLibrary = '',
        [string]$Driver = '',
        [string]$Inf = '',
        [string]$Catalog = '',
        [string]$ControlTool = '',
        [string]$RuntimePdb = '',
        [string]$DriverPdb = '',
        [string]$ControlPdb = ''
    )

    $platformDirectory = if ($Architecture -eq 'arm64') { 'ARM64' } else { 'x64' }
    $repositoryRoot = [string]$Context.RepositoryRoot
    $generatedRoot = [string]$Context.GeneratedRoot
    $binaryBaseName = [string]$Context.BinaryBaseName
    $controlBaseName = [string]$Context.ControlBaseName

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
    if ([string]::IsNullOrWhiteSpace($RuntimePdb)) {
        $RuntimePdb = Join-Path $repositoryRoot "$platformDirectory\$Configuration\$binaryBaseName.pdb"
    }
    if ([string]::IsNullOrWhiteSpace($DriverPdb)) {
        $DriverPdb = Join-Path $repositoryRoot "$platformDirectory\$Configuration\Driver\$binaryBaseName.pdb"
    }
    if ([string]::IsNullOrWhiteSpace($ControlPdb)) {
        $ControlPdb = Join-Path $repositoryRoot "$platformDirectory\$Configuration\$controlBaseName.pdb"
    }

    return [pscustomobject]@{
        RuntimeDll = [System.IO.Path]::GetFullPath($RuntimeDll)
        ImportLibrary = [System.IO.Path]::GetFullPath($ImportLibrary)
        Driver = [System.IO.Path]::GetFullPath($Driver)
        Inf = [System.IO.Path]::GetFullPath($Inf)
        Catalog = [System.IO.Path]::GetFullPath($Catalog)
        ControlTool = [System.IO.Path]::GetFullPath($ControlTool)
        RuntimePdb = [System.IO.Path]::GetFullPath($RuntimePdb)
        DriverPdb = [System.IO.Path]::GetFullPath($DriverPdb)
        ControlPdb = [System.IO.Path]::GetFullPath($ControlPdb)
    }
}

Export-ModuleMember -Function Get-DistributionBuildContext, Resolve-DistributionArtifactPaths
