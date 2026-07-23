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
Assert-True ($buildSource.Contains("[ValidateSet('Off', 'TestSign', 'ProductionSign')]")) 'Driver signing mode is not constrained to WDK signing modes'
Assert-True ($buildSource.Contains("[string]`$DriverSignMode = 'Off'")) 'Driver signing is not deterministic by default'
Assert-True ($buildSource.Contains('/p:SignMode=$DriverSignMode')) 'The selected driver signing mode is not passed to MSBuild'

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
$dokanRuntimeSource = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'dokan\dokan.c')
$driverRuntimeSource = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'sys\dokan.c')
$driverHeaderSource = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'sys\dokan.h')
$driverInitializationSource = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'sys\init.c')
$driverCreateSource = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'sys\create.c')
$driverCloseSource = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'sys\close.c')
$driverDispatchSource = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'sys\dispatch.c')
$driverFileSystemControlSource = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'sys\fscontrol.c')
$driverEventSource = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'sys\event.c')
$driverPublicHeaderSource = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'sys\public.h')
$dokanControlSource = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'dokan_control\dokanctl.c')
$dokanExportsSource = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'dokan\dokan.def')
Assert-True (
    $dokanRuntimeSource.Contains('NamespacePathsEqual(volumeName, finalGuidPath)')) `
    'Mount Manager readiness does not compare the assigned volume GUID with the handle GUID'
Assert-True (
    -not $dokanRuntimeSource.Contains('NamespacePathsEqual(expectedVolumeName, finalGuidPath)')) `
    'Mount Manager readiness still compares an internal device GUID with the assigned volume GUID'
Assert-True (
    -not $dokanRuntimeSource.Contains('VOLUME_NAME_DOS')) `
    'Mount Manager readiness still requires an arbitrary DOS alias to equal the requested mount point'
Assert-True (
    -not $driverHeaderSource.Contains('ULONG Counter;')) `
    'Unmounted devices still carry an arbitrary delayed-delete counter'
Assert-True (
    -not $driverInitializationSource.Contains('deviceEntry->Counter')) `
    'Unmounted devices still wait for arbitrary timer cycles after their references reach zero'
Assert-True (
    $driverInitializationSource.Contains('KeSetEvent(&dokanGlobal->DeleteDeviceEvent')) `
    'Queueing an unmounted device does not wake the device-deletion worker'
$clearVpbIndex = $driverInitializationSource.IndexOf('deviceEntry->DiskDeviceObject->Vpb->DeviceObject = NULL')
$deleteDiskDeviceIndex = $driverInitializationSource.IndexOf('IoDeleteDevice(deviceEntry->DiskDeviceObject)')
Assert-True (
    $clearVpbIndex -ge 0 -and $deleteDiskDeviceIndex -gt $clearVpbIndex) `
    'Delayed deletion accesses the disk device VPB after IoDeleteDevice'
foreach ($ownedDeviceReference in @(
        'ObReferenceObject(deviceObject);',
        'ObReferenceObject(fsDiskDeviceObject);',
        'ObReferenceObject(fsCdDeviceObject);',
        'ObReferenceObject(diskDeviceObject);'
    )) {
    Assert-True (
        -not $driverInitializationSource.Contains($ownedDeviceReference)) `
        "Driver initialization leaks its owned device reference: $ownedDeviceReference"
}
Assert-True (
    -not $driverFileSystemControlSource.Contains('ObReferenceObject(volDeviceObject);')) `
    'Volume mounting leaks its owned volume-device reference'
$stopDeleteThreadPattern =
    'DokanStopDeleteDeviceThread[\s\S]*?' +
    'KeSetEvent\(&dokanGlobal->KillDeleteDeviceEvent[\s\S]*?' +
    'KeWaitForSingleObject\(dokanGlobal->DeviceDeleteThread[\s\S]*?' +
    'ObDereferenceObject\(dokanGlobal->DeviceDeleteThread\)[\s\S]*?' +
    'dokanGlobal->DeviceDeleteThread = NULL'
Assert-True (
    [regex]::IsMatch($driverInitializationSource, $stopDeleteThreadPattern)) `
    'Device-deletion worker ownership is not joined and released before global teardown'
$stopDeleteThreadIndex = $driverRuntimeSource.IndexOf('DokanStopDeleteDeviceThread(dokanGlobal)')
$deleteGlobalDeviceIndex = $driverRuntimeSource.IndexOf('IoDeleteDevice(dokanGlobal->DeviceObject)')
Assert-True (
    $stopDeleteThreadIndex -ge 0 -and $deleteGlobalDeviceIndex -gt $stopDeleteThreadIndex) `
    'Global teardown deletes the worker context before the device-deletion thread stops'
$deleteGlobalResourceIndex =
    $driverRuntimeSource.IndexOf('ExDeleteResourceLite(&dokanGlobal->Resource)')
Assert-True (
    $deleteGlobalResourceIndex -ge 0 -and
    $deleteGlobalDeviceIndex -gt $deleteGlobalResourceIndex) `
    'Global teardown accesses the device extension after deleting its device object'
Assert-True (
    $driverPublicHeaderSource.Contains('FSCTL_PREPARE_UNLOAD')) `
    'The driver protocol does not expose explicit unload preparation'
Assert-True (
    $driverHeaderSource.Contains('volatile LONG UnloadPending;') -and
    $driverHeaderSource.Contains('volatile LONG FileSystemsRegistered;')) `
    'Global state does not model unload preparation and file-system registration ownership'
Assert-True (
    $driverFileSystemControlSource.Contains('SeSinglePrivilegeCheck') -and
    $driverFileSystemControlSource.Contains('DokanPrepareForUnload(RequestContext->DokanGlobal)')) `
    'Unload preparation is not privilege-gated at the driver boundary'
Assert-True (
    $driverEventSource.Contains('RequestContext->DokanGlobal->UnloadPending')) `
    'Mount startup is not rejected after unload preparation begins'
Assert-True (
    $driverInitializationSource.Contains('IsListEmpty(&dokanGlobal->MountPointList)') -and
    $driverInitializationSource.Contains('IsListEmpty(&dokanGlobal->DeviceDeleteList)') -and
    $driverInitializationSource.Contains('DokanUnregisterFileSystems(dokanGlobal)')) `
    'Unload preparation does not require empty mount state before unregistering the file system'
Assert-True (
    $driverHeaderSource.Contains('volatile LONG GlobalControlHandleCount;') -and
    $driverHeaderSource.Contains('volatile LONG GlobalControlTeardownClaimed;')) `
    'Global control handles and one-shot teardown ownership are not modeled explicitly'
Assert-True (
    $driverCreateSource.Contains('DokanRegisterGlobalControlHandle(RequestContext->DokanGlobal)') -and
    $driverCloseSource.Contains('DokanReleaseGlobalControlHandle(RequestContext->DokanGlobal)')) `
    'Global control create and close do not participate in unload lifecycle ownership'
Assert-True (
    $driverInitializationSource.Contains('dokanGlobal->GlobalControlHandleCount != 1') -and
    $driverInitializationSource.Contains('&dokanGlobal->GlobalControlTeardownClaimed')) `
    'Unload preparation can commit while foreign global handles exist or teardown can run twice'
Assert-True (
    $driverDispatchSource.Contains('CleanupGlobalDiskDevice(globalToDelete)')) `
    'The last prepared global close does not delete control devices after request logging finishes'
Assert-True (
    -not $driverRuntimeSource.Contains('deviceObject = DriverObject->DeviceObject') -and
    $driverRuntimeSource.Contains('ASSERT(DriverObject->DeviceObject == NULL)')) `
    'DriverUnload still owns device deletion instead of requiring prepared close teardown'
Assert-True (
    $dokanRuntimeSource.Contains('DokanPrepareDriverUnload') -and
    $dokanControlSource.Contains("case L'p':") -and
    $dokanExportsSource.Contains('DokanPrepareDriverUnload @36')) `
    'The generic control tool cannot request the driver unload-preparation contract'
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
$driverDigestAlgorithms = @($driverProject.SelectNodes(
        '//msbuild:ItemDefinitionGroup/msbuild:DriverSign/msbuild:FileDigestAlgorithm',
        $driverNamespaceManager) |
    ForEach-Object { $_.InnerText } |
    Select-Object -Unique)
Assert-True (
    $driverDigestAlgorithms.Count -eq 1 -and $driverDigestAlgorithms[0] -ceq 'sha256') `
    'WDK-managed driver signing does not explicitly use SHA-256 file digests'

Write-Host 'Build environment tests passed.'
