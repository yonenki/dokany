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

Write-Host 'Build environment tests passed.'
