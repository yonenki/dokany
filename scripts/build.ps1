param (
	[string[]]$BuildPart = @('win', 'cygwin'),
	[string[]]$Platforms = @('Win32', 'x64', 'ARM', 'ARM64'),
	[string[]]$Configurations = @('Release', 'Debug'),
	[string]$DistributionProfile = '.\profiles\upstream.json',
	[string]$PlatformToolset = '',
	[string]$WindowsTargetPlatformVersion = ''
)

. .\scripts\build_helper.ps1

$ErrorActionPreference = "Stop"

Add-VisualStudio-Path

if ([string]::IsNullOrWhiteSpace($PlatformToolset)) {
	$vsWhere = "${Env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
	$visualStudioVersion = & $vsWhere -latest -products * -requires Microsoft.Component.MSBuild -property installationVersion
	$visualStudioMajor = [int]($visualStudioVersion -split '\.')[0]
	$PlatformToolset = switch ($visualStudioMajor) {
		{ $_ -ge 17 } { 'v143'; break }
		16 { 'v142'; break }
		default { throw "Unsupported Visual Studio major version: $visualStudioMajor" }
	}
}

if ([string]::IsNullOrWhiteSpace($WindowsTargetPlatformVersion)) {
	$windowsKitIncludeRoot = "${Env:ProgramFiles(x86)}\Windows Kits\10\Include"
	$WindowsTargetPlatformVersion = Get-ChildItem -LiteralPath $windowsKitIncludeRoot -Directory |
		ForEach-Object {
			$parsed = $null
			if ([version]::TryParse($_.Name, [ref]$parsed)) { $parsed }
		} |
		Sort-Object -Descending |
		Select-Object -First 1
	if ($null -eq $WindowsTargetPlatformVersion) {
		throw "No Windows 10/11 SDK was found below $windowsKitIncludeRoot."
	}
	$WindowsTargetPlatformVersion = $WindowsTargetPlatformVersion.ToString()
}

$distributionProfilePath = (Resolve-Path -LiteralPath $DistributionProfile).Path
$profileInfoJson = & dotnet run --project .\tools\DistributionProfile\DistributionProfile.csproj -- validate $distributionProfilePath
if ($LASTEXITCODE -ne 0) {
	throw "Distribution profile validation failed with exit code $LASTEXITCODE."
}
$profileInfo = $profileInfoJson | ConvertFrom-Json
$distributionProfileRoot = Join-Path (Resolve-Path .).Path "BuildOutput\profiles\$($profileInfo.distributionId)-$($profileInfo.profileHash)"
Exec-External { dotnet run --project .\tools\DistributionProfile\DistributionProfile.csproj -- generate $distributionProfilePath $distributionProfileRoot }
$env:DOKAN_DISTRIBUTION_PROFILE_ROOT = $distributionProfileRoot

if ($env:APPVEYOR -eq "True") { $CI_BUILD_ARG="/l:C:\Program Files\AppVeyor\BuildAgent\Appveyor.MSBuildLogger.dll" }
$msBuildPath=& Get-Command msbuild | Select-Object -ExpandProperty Definition
if (!([bool](Get-Command -Name buildWrapper -ErrorAction SilentlyContinue))) {
	set-alias buildWrapper "$msBuildPath"
}

if ($BuildPart -contains 'win') {
	foreach ($Configuration in $Configurations) {
		foreach ($Platform in $Platforms) {
			Write-Host Build dokan $Configuration $Platform ...
			Exec-External { buildWrapper .\dokan.sln /p:Configuration=$Configuration /p:Platform=$Platform /p:PlatformToolset=$PlatformToolset /p:WindowsTargetPlatformVersion=$WindowsTargetPlatformVersion /p:DokanDistributionProfileRoot="$distributionProfileRoot" /t:Build $CI_BUILD_ARG }
			Write-Host Build dokan $Configuration $Platform done !
		}
	}
}

if ($BuildPart -contains 'cygwin') {
	if ((Test-Path -Path env:CYGWIN_INST_DIR) -or (Test-Path -Path 'C:\cygwin64')) {
		$ErrorActionPreference = "Continue" #cmake has normal stdout through stderr...
		Exec-External { ./dokan_fuse/build.ps1 }
		$ErrorActionPreference = "Stop"
	} else {
		Write-Host "Cygwin/Msys2 build disabled"
	}
}
