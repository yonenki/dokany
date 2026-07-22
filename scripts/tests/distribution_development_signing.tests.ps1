$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool]$Actual, [string]$Message) {
    if (-not $Actual) { throw $Message }
}

$scriptsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifactModulePath = Join-Path $scriptsRoot 'distribution_artifacts.psm1'
$signingModulePath = Join-Path $scriptsRoot 'distribution_development_signing.psm1'
$certificateScriptPath = Join-Path $scriptsRoot 'new_distribution_development_certificate.ps1'

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

$certificateSource = Get-Content -Raw -LiteralPath $certificateScriptPath
Assert-True ($certificateSource.Contains('TrustForTestMachine')) 'Certificate creation does not require an explicit trust intent'
Assert-True ($certificateSource.Contains("Cert:\LocalMachine\Root")) 'Certificate is not installed in LocalMachine Root'
Assert-True ($certificateSource.Contains("Cert:\LocalMachine\TrustedPublisher")) 'Certificate is not installed in LocalMachine TrustedPublisher'
Assert-True (-not $certificateSource.Contains('EV_CERTTHUMBPRINT')) 'Development signing is coupled to release-signing credentials'

Write-Host 'Distribution development signing tests passed.'
