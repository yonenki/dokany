#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture,
    [Parameter(Mandatory = $true)]
    [string]$DistributionProfile,
    [string]$Configuration = 'Release',
    [Parameter(Mandatory = $true)]
    [string]$CertificateThumbprint,
    [ValidateSet('CurrentUser', 'LocalMachine')]
    [string]$CertificateStoreLocation = 'LocalMachine',
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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'distribution_development_signing.psm1') -Force

$result = Invoke-DistributionDevelopmentSigning @PSBoundParameters
$result | ConvertTo-Json -Depth 5
