$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool]$Actual, [string]$Message) {
    if (-not $Actual) { throw $Message }
}

$buildScriptPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\build.ps1'))
$buildSource = Get-Content -Raw -LiteralPath $buildScriptPath
$firstDotnetInvocation = $buildSource.IndexOf('& dotnet run', [System.StringComparison]::Ordinal)
$buildHelperPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\build_helper.ps1'))
. $buildHelperPath

Assert-True ($firstDotnetInvocation -ge 0) 'build.ps1 does not invoke the distribution profile generator'
foreach ($setting in @('DOTNET_NOLOGO', 'DOTNET_CLI_TELEMETRY_OPTOUT')) {
    $settingIndex = $buildSource.IndexOf("`$env:$setting", [System.StringComparison]::Ordinal)
    Assert-True ($settingIndex -ge 0) "build.ps1 does not set $setting"
    Assert-True ($settingIndex -lt $firstDotnetInvocation) "$setting is set after the first dotnet invocation"
}

Assert-True ($buildSource.Contains('$ciBuildArgument = $null')) 'Non-AppVeyor builds do not initialize the optional CI logger argument'
Assert-True (-not $buildSource.Contains('$CI_BUILD_ARG')) 'The legacy conditionally initialized CI argument remains in build.ps1'

$originalProcessorArchitecture = $env:PROCESSOR_ARCHITECTURE
$originalProcessorArchitectureW6432 = $env:PROCESSOR_ARCHITEW6432
try {
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'
    $env:PROCESSOR_ARCHITEW6432 = $null
    Assert-True ((Get-NativeMsBuildHostDirectory) -ceq 'amd64') 'x64 hosts do not select 64-bit MSBuild'

    $env:PROCESSOR_ARCHITECTURE = 'x86'
    $env:PROCESSOR_ARCHITEW6432 = 'ARM64'
    Assert-True ((Get-NativeMsBuildHostDirectory) -ceq 'arm64') 'ARM64 hosts do not select native MSBuild'

    $env:PROCESSOR_ARCHITECTURE = 'x86'
    $env:PROCESSOR_ARCHITEW6432 = $null
    $unsupportedHostRejected = $false
    try {
        Get-NativeMsBuildHostDirectory | Out-Null
    } catch {
        $unsupportedHostRejected = $true
    }
    Assert-True $unsupportedHostRejected 'Unsupported 32-bit build hosts do not fail closed'
} finally {
    $env:PROCESSOR_ARCHITECTURE = $originalProcessorArchitecture
    $env:PROCESSOR_ARCHITEW6432 = $originalProcessorArchitectureW6432
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$solutionSource = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'dokan.sln')
$projectMatches = [regex]::Matches($solutionSource, '"([^"\r\n]+\.vcxproj)"')
Assert-True ($projectMatches.Count -gt 0) 'dokan.sln contains no C++ projects'
foreach ($projectMatch in $projectMatches) {
    $projectPath = Join-Path $repositoryRoot $projectMatch.Groups[1].Value
    $projectSource = Get-Content -Raw -LiteralPath $projectPath
    Assert-True ($projectSource.Contains('Dokan.props')) "$($projectMatch.Groups[1].Value) does not import the distribution profile properties"

    [xml]$project = $projectSource
    $namespaceManager = [System.Xml.XmlNamespaceManager]::new($project.NameTable)
    $namespaceManager.AddNamespace('msbuild', 'http://schemas.microsoft.com/developer/msbuild/2003')
    $includeDirectories = @($project.SelectNodes(
            '//msbuild:ClCompile/msbuild:AdditionalIncludeDirectories',
            $namespaceManager))
    foreach ($includeDirectory in $includeDirectories) {
        Assert-True (
            $includeDirectory.InnerText.Contains('%(AdditionalIncludeDirectories)')) `
            "$($projectMatch.Groups[1].Value) discards inherited compiler include directories"
    }
}

[xml]$driverProject = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'sys\sys.vcxproj')
$driverNamespaceManager = [System.Xml.XmlNamespaceManager]::new($driverProject.NameTable)
$driverNamespaceManager.AddNamespace('msbuild', 'http://schemas.microsoft.com/developer/msbuild/2003')
$localProperties = @($driverProject.Project.TreatAsLocalProperty -split ';')
Assert-True ($localProperties -contains 'PlatformToolset') 'The driver project allows solution-level PlatformToolset to replace the WDK toolset'
$driverToolsets = @($driverProject.SelectNodes(
        '//msbuild:PropertyGroup[@Label="Configuration"]/msbuild:PlatformToolset',
        $driverNamespaceManager) |
    ForEach-Object { $_.InnerText } |
    Select-Object -Unique)
Assert-True (
    $driverToolsets.Count -eq 1 -and $driverToolsets[0] -ceq 'WindowsKernelModeDriver10.0') `
    'The driver project does not consistently select the WDK kernel-mode toolset'
$driverTargetVersions = @($driverProject.SelectNodes(
        '//msbuild:PropertyGroup[@Label="Configuration"]/msbuild:TargetVersion',
        $driverNamespaceManager) |
    ForEach-Object { $_.InnerText } |
    Select-Object -Unique)
Assert-True (
    $driverTargetVersions.Count -eq 1 -and $driverTargetVersions[0] -ceq 'Windows10') `
    'The driver configurations do not consistently target the supported Windows baseline'

Write-Host 'Build environment tests passed.'
