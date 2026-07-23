$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool]$Actual, [string]$Message) {
    if (-not $Actual) { throw $Message }
}

$buildScriptPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\build.ps1'))
$buildSource = Get-Content -Raw -LiteralPath $buildScriptPath
$firstDotnetInvocation = $buildSource.IndexOf('& dotnet run', [System.StringComparison]::Ordinal)

Assert-True ($firstDotnetInvocation -ge 0) 'build.ps1 does not invoke the distribution profile generator'
foreach ($setting in @('DOTNET_NOLOGO', 'DOTNET_CLI_TELEMETRY_OPTOUT')) {
    $settingIndex = $buildSource.IndexOf("`$env:$setting", [System.StringComparison]::Ordinal)
    Assert-True ($settingIndex -ge 0) "build.ps1 does not set $setting"
    Assert-True ($settingIndex -lt $firstDotnetInvocation) "$setting is set after the first dotnet invocation"
}

Assert-True ($buildSource.Contains('$ciBuildArgument = $null')) 'Non-AppVeyor builds do not initialize the optional CI logger argument'
Assert-True (-not $buildSource.Contains('$CI_BUILD_ARG')) 'The legacy conditionally initialized CI argument remains in build.ps1'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$solutionSource = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'dokan.sln')
$projectMatches = [regex]::Matches($solutionSource, '"([^"\r\n]+\.vcxproj)"')
Assert-True ($projectMatches.Count -gt 0) 'dokan.sln contains no C++ projects'
foreach ($projectMatch in $projectMatches) {
    $projectPath = Join-Path $repositoryRoot $projectMatch.Groups[1].Value
    $projectSource = Get-Content -Raw -LiteralPath $projectPath
    Assert-True ($projectSource.Contains('Dokan.props')) "$($projectMatch.Groups[1].Value) does not import the distribution profile properties"
}

Write-Host 'Build environment tests passed.'
