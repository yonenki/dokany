$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool]$Actual, [string]$Message) {
    if (-not $Actual) { throw $Message }
}

$scriptsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifactModulePath = Join-Path $scriptsRoot 'distribution_artifacts.psm1'
$signingModulePath = Join-Path $scriptsRoot 'distribution_development_signing.psm1'
$certificateScriptPath = Join-Path $scriptsRoot 'new_distribution_development_certificate.ps1'
$packageScriptPath = Join-Path $scriptsRoot 'package_distribution.ps1'

Import-Module $signingModulePath -Force
Import-Module $artifactModulePath -Force

$context = [pscustomobject]@{
    RepositoryRoot = 'C:\source\dokany'
    GeneratedRoot = 'C:\source\dokany\BuildOutput\profiles\acme-abc123'
    BinaryBaseName = 'acmefs2'
    ControlBaseName = 'acmectl'
}
$artifacts = Resolve-DistributionArtifactPaths `
    -Context $context `
    -Architecture x64 `
    -Configuration Release

Assert-True ($artifacts.RuntimeDll -ceq 'C:\source\dokany\x64\Release\acmefs2.dll') 'Runtime DLL path is not profile-derived'
Assert-True ($artifacts.Driver -ceq 'C:\source\dokany\x64\Release\Driver\sys\acmefs2.sys') 'Driver path is not profile-derived'
Assert-True ($artifacts.Inf -ceq 'C:\source\dokany\BuildOutput\profiles\acme-abc123\acmefs2.inf') 'INF path is not profile-derived'
Assert-True ($artifacts.Catalog -ceq 'C:\source\dokany\x64\Release\Driver\sys\acmefs2.cat') 'Catalog path is not profile-derived'
Assert-True ($artifacts.ControlTool -ceq 'C:\source\dokany\x64\Release\acmectl.exe') 'Control tool path is not profile-derived'

$plan = New-DistributionDevelopmentSigningPlan -Context $context -Artifacts $artifacts -Architecture x64
Assert-True ($plan.EmbeddedSignatureTargets.Count -eq 3) 'Signing plan must embed-sign exactly SYS, DLL, and control EXE'
Assert-True ($plan.EmbeddedSignatureTargets[0] -ceq $artifacts.Driver) 'Driver must be signed before catalog generation'
Assert-True ($plan.CatalogInputs.Count -eq 2) 'Catalog must be generated from exactly INF and SYS'
Assert-True ($plan.CatalogInputs[0] -ceq $artifacts.Inf) 'Catalog input does not include the generated INF'
Assert-True ($plan.CatalogInputs[1] -ceq $artifacts.Driver) 'Catalog input does not include the signed driver'
Assert-True ($plan.Inf2CatOs -ceq '10_X64,10_NI_X64') 'x64 signing plan does not cover the declared Windows test targets'

$arm64Plan = New-DistributionDevelopmentSigningPlan -Context $context -Artifacts $artifacts -Architecture arm64
Assert-True ($arm64Plan.Inf2CatOs -ceq '10_ARM64,10_NI_ARM64') 'ARM64 signing plan does not cover the declared Windows test targets'

$catalogTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dokany-catalog-test-$([Guid]::NewGuid().ToString('N'))"
[System.IO.Directory]::CreateDirectory($catalogTestRoot) | Out-Null
$previousCatalogTestLog = $env:DOKANY_CATALOG_TEST_LOG
try {
    $catalogTestLog = Join-Path $catalogTestRoot 'signtool.log'
    $catalogTestCatalog = Join-Path $catalogTestRoot 'family.cat'
    $catalogTestInf = Join-Path $catalogTestRoot 'family.inf'
    $catalogTestDriver = Join-Path $catalogTestRoot 'family.sys'
    $catalogTestSignTool = Join-Path $catalogTestRoot 'signtool.ps1'
    foreach ($path in @($catalogTestCatalog, $catalogTestInf, $catalogTestDriver)) {
        [System.IO.File]::WriteAllText($path, $path)
    }
    [System.IO.File]::WriteAllText(
        $catalogTestSignTool,
        'param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)' + [Environment]::NewLine +
        '[System.IO.File]::AppendAllText($env:DOKANY_CATALOG_TEST_LOG, ($Arguments -join "|") + [Environment]::NewLine)' + [Environment]::NewLine +
        'exit 0')
    $env:DOKANY_CATALOG_TEST_LOG = $catalogTestLog

    Assert-DistributionCatalogMembership `
        -Catalog $catalogTestCatalog `
        -Inputs @($catalogTestInf, $catalogTestDriver) `
        -SignTool $catalogTestSignTool

    $catalogVerifications = @(Get-Content -LiteralPath $catalogTestLog)
    Assert-True ($catalogVerifications.Count -eq 2) 'Catalog membership verification did not inspect every input'
    Assert-True ($catalogVerifications[0].Contains($catalogTestInf)) 'Catalog membership verification did not inspect the INF'
    Assert-True ($catalogVerifications[1].Contains($catalogTestDriver)) 'Catalog membership verification did not inspect the SYS'
}
finally {
    $env:DOKANY_CATALOG_TEST_LOG = $previousCatalogTestLog
    Remove-Item -LiteralPath $catalogTestRoot -Recurse -Force
}

$certificateSource = Get-Content -Raw -LiteralPath $certificateScriptPath
Assert-True ($certificateSource.Contains('TrustForTestMachine')) 'Certificate creation does not require an explicit trust intent'
Assert-True ($certificateSource.Contains("Cert:\LocalMachine\Root")) 'Certificate is not installed in LocalMachine Root'
Assert-True ($certificateSource.Contains("Cert:\LocalMachine\TrustedPublisher")) 'Certificate is not installed in LocalMachine TrustedPublisher'
Assert-True (-not $certificateSource.Contains('EV_CERTTHUMBPRINT')) 'Development signing is coupled to release-signing credentials'

$packageSource = Get-Content -Raw -LiteralPath $packageScriptPath
Assert-True ($packageSource.Contains('Assert-DistributionCatalogMembership')) 'Signed package creation does not verify catalog membership'
Assert-True ($packageSource.Contains('-Inputs @($Inf, $Driver)')) 'Signed package creation does not verify both the packaged INF and SYS'

Write-Host 'Distribution development signing tests passed.'
