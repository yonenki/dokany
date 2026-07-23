# Security regression tests for the dokany fork (yonenki/textil issues).
#
# Prerequisites:
#   * The fork driver (dokan2.sys) installed and running (test-signed).
#   * Built test tools: build_security_tests.ps1
#   * A branch-built mirror.exe for the rename storm / functional smoke test
#     (default: samples\dokan_mirror\x64\Release\mirror.exe).
#
# Each test prints PASS / FAIL / XFAIL / XPASS / SKIP. XFAIL marks known
# issues that are tracked but not yet fixed (the test asserts the secure
# behavior and is expected to fail until then).
param(
    [string]$BinDir = "$PSScriptRoot\bin",
    [string]$MirrorExe = "$PSScriptRoot\..\..\..\samples\dokan_mirror\x64\Release\mirror.exe",
    [string]$DokanNpDll = "$PSScriptRoot\..\..\..\dokan_np\x64\Release\dokannp2.dll",
    [int]$StormSeconds = 60,
    [int]$ScalingMounts = 150
)

$ErrorActionPreference = 'Continue'
$results = New-Object System.Collections.ArrayList

function Add-Result($Name, $Status, $Detail) {
    [void]$results.Add([pscustomobject]@{ Test = $Name; Status = $Status; Detail = $Detail })
    Write-Host ("[{0}] {1} - {2}" -f $Status, $Name, $Detail)
}

function Get-BugcheckCount {
    return @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting' } -ErrorAction SilentlyContinue).Count
}

$script:bugchecksAtStart = Get-BugcheckCount

function Stop-TestProcesses {
    Get-Process eventwrite_fshost, bigsd_fshost, mirror, memfs, mountmany, mountstorm -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Assert-NoNewBugcheck($Name) {
    if ((Get-BugcheckCount) -gt $script:bugchecksAtStart) {
        Add-Result $Name 'FAIL' 'a new bugcheck was recorded during the test run'
        return $false
    }
    return $true
}

if (-not (Test-Path "$BinDir\eventwrite_sweep.exe")) {
    throw "Test tools not found in $BinDir. Run build_security_tests.ps1 first."
}

Stop-TestProcesses
Start-Sleep 2
# Use run-unique mount points so leftovers from previous runs can never make
# a new mount fail on a stale internal mount entry.
$runId = Get-Date -Format 'HHmmss'
$t2Mount = "C:\mnt\sectest-$runId-t2"
$t3Mount = "C:\mnt\sectest-$runId-t3"
$rxMount = "C:\mnt\sectest-$runId-rx"
$smokeMount = "C:\mnt\sectest-$runId-smoke"
New-Item -ItemType Directory -Force $t2Mount, $t3Mount -ErrorAction SilentlyContinue | Out-Null

# ---------------------------------------------------------------- #2183
$p = Start-Process -PassThru -FilePath "$BinDir\eventwrite_fshost.exe" -ArgumentList $t2Mount -WindowStyle Hidden
Start-Sleep 5
if ($p.HasExited) {
    Add-Result 'EventWrite-2183' 'SKIP' 'FS host failed to mount (driver not running?)'
} else {
    $out = & "$BinDir\eventwrite_sweep.exe" $t2Mount 20000 2>&1 | Out-String
    Stop-TestProcesses
    if ($out -match 'sweep done \(SURVIVED\)' -and (Assert-NoNewBugcheck 'EventWrite-2183')) {
        Add-Result 'EventWrite-2183' 'PASS' 'FSCTL_EVENT_WRITE sweep was fully rejected, no crash'
    } elseif ($out -notmatch 'sweep done') {
        Add-Result 'EventWrite-2183' 'FAIL' "sweep did not complete: $($out.Trim())"
    }
}

# ---------------------------------------------------------------- #2184
$p = Start-Process -PassThru -FilePath "$BinDir\eventwrite_fshost.exe" -ArgumentList $t2Mount -WindowStyle Hidden
Start-Sleep 5
if ($p.HasExited) {
    Add-Result 'AccessToken-2184' 'SKIP' 'FS host failed to mount'
} else {
    $out = & "$BinDir\token_sweep.exe" $t2Mount 20000 2>&1 | Out-String
    Stop-TestProcesses
    if ($out -match 'stolen=0' -and (Assert-NoNewBugcheck 'AccessToken-2184')) {
        Add-Result 'AccessToken-2184' 'PASS' 'no token could be stolen by a foreign process'
    } else {
        Add-Result 'AccessToken-2184' 'FAIL' "token theft still possible: $($out.Trim())"
    }
}

# ---------------------------------------------------------------- #2185
$p = Start-Process -PassThru -FilePath "$BinDir\bigsd_fshost.exe" -ArgumentList $t3Mount -WindowStyle Hidden
Start-Sleep 5
if ($p.HasExited) {
    Add-Result 'QuerySecurity-2185' 'SKIP' 'FS host failed to mount'
} else {
    $out = & "$BinDir\query_sec.exe" "$t3Mount\target.txt" 2>&1 | Out-String
    Start-Sleep 1
    $mountAlive = Test-Path "$t3Mount\target.txt"
    $hostAlive = -not $p.HasExited
    Stop-TestProcesses
    if (($out -match 'st=0xc0000023 needed=60000') -and $mountAlive -and $hostAlive -and
        (Assert-NoNewBugcheck 'QuerySecurity-2185')) {
        Add-Result 'QuerySecurity-2185' 'PASS' 'overflow replies are header-only; volume survived'
    } else {
        Add-Result 'QuerySecurity-2185' 'FAIL' "out=$($out.Trim()) mountAlive=$mountAlive hostAlive=$hostAlive"
    }
}

# ---------------------------------------------------------------- #2195
if (Test-Path $MirrorExe) {
    Copy-Item "$BinDir\dokan2.dll" (Split-Path $MirrorExe) -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force 'C:\FSTMP\sec-rx', $rxMount -ErrorAction SilentlyContinue | Out-Null
    $m = Start-Process -PassThru -FilePath $MirrorExe -ArgumentList '/r','C:\FSTMP\sec-rx','/l',$rxMount,'/i','30000' -WindowStyle Hidden
    Start-Sleep 4
    if ($m.HasExited) {
        Add-Result 'RenameEx-2195' 'SKIP' 'mirror failed to mount'
    } else {
        $out = & "$BinDir\renameex_storm.exe" $rxMount $StormSeconds 2>&1 | Out-String
        Stop-TestProcesses
        if ($out -match 'done renames=(\d+)' -and [int]$Matches[1] -gt 100 -and
            (Assert-NoNewBugcheck 'RenameEx-2195')) {
            Add-Result 'RenameEx-2195' 'PASS' "rename-Ex storm completed ($($Matches[1]) renames)"
        } else {
            Add-Result 'RenameEx-2195' 'FAIL' "storm failed: $($out.Trim())"
        }
    }
} else {
    Add-Result 'RenameEx-2195' 'SKIP' "mirror.exe not found at $MirrorExe"
}

# ---------------------------------------------------------------- #2196
$out = & "$BinDir\mountstorm.exe" 8 $StormSeconds 2>&1 | Out-String
Stop-TestProcesses
if ($out -match 'done cycles=(\d+)' -and [int]$Matches[1] -gt 50 -and
    (Assert-NoNewBugcheck 'MountStorm-2196')) {
    Add-Result 'MountStorm-2196' 'PASS' "mount/unmount storm completed ($($Matches[1]) cycles)"
} else {
    Add-Result 'MountStorm-2196' 'FAIL' "storm failed: $($out.Trim())"
}

# ------------------------------------------------- #2205 scaling / #2199 quota
Remove-Item "$BinDir\mountmany.out", "$BinDir\mountmany.err" -Force -ErrorAction SilentlyContinue
$threadsBefore = (Get-Process -Id 4).Threads.Count
$mm = Start-Process -PassThru -FilePath "$BinDir\mountmany.exe" -ArgumentList "$ScalingMounts",'1','30000' `
    -RedirectStandardOutput "$BinDir\mountmany.out" -RedirectStandardError "$BinDir\mountmany.err" -WindowStyle Hidden
# Wait until mountmany prints its final line, then measure kernel threads
# while the mounts are still being held.
$deadline = (Get-Date).AddMinutes(10)
$out = ''
while ((Get-Date) -lt $deadline) {
    Start-Sleep 3
    $out = Get-Content "$BinDir\mountmany.out" -Raw -ErrorAction SilentlyContinue
    if ($out -match 'final: mounted=') { break }
}
$threadsDuring = (Get-Process -Id 4).Threads.Count
$mm | Wait-Process -Timeout 120 -ErrorAction SilentlyContinue
Stop-TestProcesses
if ($out -match 'final: mounted=(\d+) fail=(\d+)') {
    $mounted = [int]$Matches[1]; $failed = [int]$Matches[2]
    $perMount = if ($mounted -gt 0) { [math]::Round(($threadsDuring - $threadsBefore) / $mounted, 2) } else { 99 }
    if ($mounted -ge [int]($ScalingMounts * 0.9) -and (Assert-NoNewBugcheck 'Scaling-2205')) {
        Add-Result 'Scaling-2205' 'PASS' "ThreadCount=1 mounted $mounted/$ScalingMounts volumes, ~$perMount kernel threads/mount"
    } else {
        Add-Result 'Scaling-2205' 'FAIL' "only $mounted/$ScalingMounts mounted ($perMount threads/mount)"
    }
    if ($mounted -ge 30) {
        Add-Result 'MountQuota-2199' 'XFAIL' "no mount quota exists: $mounted volumes were mounted without restriction (tracked in textil#2199)"
    } else {
        Add-Result 'MountQuota-2199' 'XPASS' 'a mount quota appears to be in place; update the test to PASS'
    }
} else {
    Add-Result 'Scaling-2205' 'FAIL' "mountmany produced no result: $($out.Trim())"
}

# ---------------------------------------------------------------- #2198
if (Test-Path $DokanNpDll) {
    if (Test-Path $MirrorExe) {
        New-Item -ItemType Directory -Force 'C:\FSTMP\sec-np' -ErrorAction SilentlyContinue | Out-Null
        $m = Start-Process -PassThru -FilePath $MirrorExe -ArgumentList '/r','C:\FSTMP\sec-np','/l','R','/n','\\dokan\sectest' -WindowStyle Hidden
        Start-Sleep 5
        $out = & "$BinDir\np_oob_write.exe" $DokanNpDll 'R:' 2>&1 | Out-String
        Stop-TestProcesses
        if ($out -match 'SKIP') {
            Add-Result 'NpGetConnection-2198' 'SKIP' $out.Trim()
        } elseif ($out -match 'OOB write confirmed') {
            Add-Result 'NpGetConnection-2198' 'XFAIL' 'NPGetConnection still writes 2 bytes past the caller buffer (tracked in textil#2198)'
        } elseif ($out -match 'no OOB write') {
            Add-Result 'NpGetConnection-2198' 'XPASS' 'NPGetConnection OOB write is fixed; flip this test to PASS'
        } else {
            Add-Result 'NpGetConnection-2198' 'FAIL' "unexpected output: $($out.Trim())"
        }
    } else {
        Add-Result 'NpGetConnection-2198' 'SKIP' 'mirror.exe not found for UNC mount'
    }
} else {
    Add-Result 'NpGetConnection-2198' 'SKIP' "dokannp dll not found at $DokanNpDll"
}

# ------------------------------------------------- functional smoke (mirror)
if (Test-Path $MirrorExe) {
    $smokeSrc = "C:\FSTMP\sec-smoke-$runId"
    New-Item -ItemType Directory -Force $smokeSrc, $smokeMount -ErrorAction SilentlyContinue | Out-Null
    $m = Start-Process -PassThru -FilePath $MirrorExe -ArgumentList '/r',$smokeSrc,'/l',$smokeMount,'/i','30000' -WindowStyle Hidden
    Start-Sleep 4
    $ok = $false
    try {
        'hello' | Out-File "$smokeMount\s.txt" -ErrorAction Stop
        $read = Get-Content "$smokeMount\s.txt" -ErrorAction Stop
        Rename-Item "$smokeMount\s.txt" 's2.txt' -ErrorAction Stop
        $ok = ($read -eq 'hello') -and (Test-Path "$smokeMount\s2.txt")
    } catch { $ok = $false }
    Stop-TestProcesses
    if ($ok) { Add-Result 'MirrorSmoke' 'PASS' 'create/read/rename on a mounted volume works' }
    else { Add-Result 'MirrorSmoke' 'FAIL' 'basic file operations failed' }
}

# ---------------------------------------------------------------- summary
$failCount = @($results | Where-Object Status -eq 'FAIL').Count
$passCount = @($results | Where-Object Status -eq 'PASS').Count
$xfailCount = @($results | Where-Object Status -eq 'XFAIL').Count
$skipCount = @($results | Where-Object Status -eq 'SKIP').Count
Write-Host ''
Write-Host "=== security tests: $passCount PASS, $failCount FAIL, $xfailCount XFAIL, $skipCount SKIP ==="
Stop-TestProcesses
exit $(if ($failCount -gt 0) { 1 } else { 0 })
