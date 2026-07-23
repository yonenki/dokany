function Exec-External {
  param(
	[Parameter(Position=0,Mandatory=1)][scriptblock] $command
  )
  & $command
  if ($LASTEXITCODE -ne 0) {
	throw ("Command returned non-zero error-code ${LASTEXITCODE}: $command")
  }
}

function Get-NativeMsBuildHostDirectory {
	$nativeArchitecture = if ([string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) {
		$env:PROCESSOR_ARCHITECTURE
	} else {
		$env:PROCESSOR_ARCHITEW6432
	}
	switch ($nativeArchitecture.ToUpperInvariant()) {
		'AMD64' { return 'amd64' }
		'ARM64' { return 'arm64' }
		default { throw "Unsupported Visual Studio build host architecture: $nativeArchitecture" }
	}
}

function Add-VisualStudio-Path {
	$vsWhere = "${Env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
	if (!(Test-Path -LiteralPath $vsWhere)) {
		throw "Visual Studio Installer vswhere.exe was not found."
	}

	$vsPath = & $vsWhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
	if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vsPath)) {
		throw "A launchable Visual Studio installation with MSBuild was not found."
	}

	$msBuildHostDirectory = Get-NativeMsBuildHostDirectory
	$msBuildPath = Join-Path $vsPath "MSBuild\Current\Bin\$msBuildHostDirectory"
	if (!(Test-Path -LiteralPath $msBuildPath)) {
		throw "MSBuild was not found below the selected Visual Studio installation: $vsPath"
	}

	if (($env:Path -split ';') -notcontains $msBuildPath) {
		$env:Path = "$msBuildPath;$env:Path"
	}
}
