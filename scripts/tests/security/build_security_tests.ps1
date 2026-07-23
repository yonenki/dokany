# Builds the security regression test tools in this directory.
# Requires: Visual Studio Build Tools (cl), a built dokan2.lib, and the
# generated distribution profile header directory.
param(
    [string]$DokanLibDir = "$PSScriptRoot\..\..\..\dokan\x64\Release",
    [string]$ProfileIncludeDir = '',
    [string]$OutputDir = "$PSScriptRoot\bin"
)

$ErrorActionPreference = 'Stop'

$vsWhere = "${Env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw 'Visual Studio with C++ tools not found.' }
$vsDevCmd = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'

if (-not (Test-Path "$DokanLibDir\dokan2.lib")) {
    throw "dokan2.lib not found in $DokanLibDir. Build dokan\dokan.vcxproj first (scripts/build.ps1)."
}

if ($ProfileIncludeDir -eq '') {
    $candidate = Get-ChildItem "$PSScriptRoot\..\..\..\BuildOutput\profiles" -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem $_.FullName -Directory } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($candidate) { $ProfileIncludeDir = $candidate.FullName }
}
if (-not (Test-Path "$ProfileIncludeDir\dokan_distribution_profile.h")) {
    throw "dokan_distribution_profile.h not found. Pass -ProfileIncludeDir with the generated profile directory."
}

$repoRoot = Resolve-Path "$PSScriptRoot\..\..\.."
New-Item -ItemType Directory -Force $OutputDir | Out-Null
Copy-Item "$DokanLibDir\dokan2.dll" $OutputDir -Force

$common = "/I `"$repoRoot\dokan`" /I `"$repoRoot\sys`" /I `"$ProfileIncludeDir`""
$targets = @(
    @{ Src = 'eventwrite_fshost.c'; Out = 'eventwrite_fshost.exe'; Lib = 'dokan2.lib' },
    @{ Src = 'eventwrite_sweep.c';  Out = 'eventwrite_sweep.exe';  Lib = 'dokan2.lib' },
    @{ Src = 'token_sweep.c';       Out = 'token_sweep.exe';       Lib = 'dokan2.lib advapi32.lib' },
    @{ Src = 'bigsd_fshost.c';      Out = 'bigsd_fshost.exe';      Lib = 'dokan2.lib' },
    @{ Src = 'query_sec.c';         Out = 'query_sec.exe';         Lib = '' },
    @{ Src = 'renameex_storm.c';    Out = 'renameex_storm.exe';    Lib = '' },
    @{ Src = 'mountstorm.c';        Out = 'mountstorm.exe';        Lib = 'dokan2.lib' },
    @{ Src = 'mountmany.c';         Out = 'mountmany.exe';         Lib = 'dokan2.lib' },
    @{ Src = 'np_oob_write.c';      Out = 'np_oob_write.exe';      Lib = '' }
)

$cmds = @()
foreach ($t in $targets) {
    $libPart = if ($t.Lib -ne '') { "`"$DokanLibDir\dokan2.lib`" $($t.Lib -replace 'dokan2\.lib ?', '')" } else { '' }
    if ($t.Lib -eq 'dokan2.lib') { $libPart = "`"$DokanLibDir\dokan2.lib`"" }
    $cmds += "cl /nologo /O2 /W3 $common `"$PSScriptRoot\$($t.Src)`" $libPart /Fe:`"$OutputDir\$($t.Out)`""
}
$all = ($cmds -join ' && ')
cmd /c "`"$vsDevCmd`" -arch=x64 -host_arch=x64 >nul 2>&1 && $all"
if ($LASTEXITCODE -ne 0) { throw "build failed with exit code $LASTEXITCODE" }
Write-Host "Security test tools built in $OutputDir"
