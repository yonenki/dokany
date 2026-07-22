function Exec-External {
  param(
	[Parameter(Position=0,Mandatory=1)][scriptblock] $command
  )
  & $command
  if ($LASTEXITCODE -ne 0) {
	throw ("Command returned non-zero error-code ${LASTEXITCODE}: $command")
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

	$msBuildPath = Join-Path $vsPath "MSBuild\Current\Bin"
	if (!(Test-Path -LiteralPath $msBuildPath)) {
		throw "MSBuild was not found below the selected Visual Studio installation: $vsPath"
	}

	if (($env:Path -split ';') -notcontains $msBuildPath) {
		$env:Path = "$msBuildPath;$env:Path"
	}
}
