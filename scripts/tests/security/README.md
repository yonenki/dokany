# Security regression tests

Dynamic regression tests for the security issues found during the dokany
review for product bundling (tracked in yonenki/textil). Each test is derived
from the PoC that originally demonstrated the issue on a live system.

## Covered issues

| Test | Issue | What it proves |
|---|---|---|
| `EventWrite-2183` | textil#2183 | A serial-number sweep with `FSCTL_EVENT_WRITE` from a foreign process is fully rejected (was a deterministic BSOD) |
| `AccessToken-2184` | textil#2184 | No token can be stolen from pending creates by a foreign process (was a working LPE) |
| `QuerySecurity-2185` | textil#2185 | `STATUS_BUFFER_OVERFLOW` security replies are header-only; the volume survives (was a dirty unmount DoS) |
| `RenameEx-2195` | textil#2195 | A rename-Ex/open storm completes (was an AVL corruption BSOD) |
| `MountStorm-2196` | textil#2196 | A parallel mount/unmount storm completes (was a `LIST_ENTRY` corruption BSOD) |
| `Scaling-2205` | textil#2205 | With `DOKAN_OPTIONS.ThreadCount = 1` a single host process mounts far beyond the historical ~90-mount ceiling |
| `NpGetConnection-2198` | textil#2198 (XFAIL, unfixed) | `NPGetConnection` must not write past the declared buffer size |
| `MountQuota-2199` | textil#2199 (XFAIL, by design for now) | Documents that no mount quota exists |
| `MirrorSmoke` | — | Basic create/read/rename on a mounted volume |

`XFAIL` means the secure behavior is asserted and expected to fail until the
linked issue is fixed; the suite still exits 0 while no `FAIL` is present.
When an XFAIL starts passing (XPASS), flip it to a required PASS.

## Prerequisites

- The fork driver (`dokan2.sys`) installed and running (test-signed).
- `dokan2.lib`/`dokan2.dll` built (e.g. via `scripts/build.ps1`).
- A branch-built `mirror.exe` for the rename storm, NP test and smoke test.
- The NP test additionally needs `dokannp2.dll` and creates a UNC mount.

## Usage

```powershell
# 1. Build the test tools (auto-detects VS, dokan2.lib and the generated
#    distribution profile headers)
.\scripts\tests\security\build_security_tests.ps1

# 2. Run the suite
.\scripts\tests\security\security.tests.ps1
```

Useful parameters: `-StormSeconds 60`, `-ScalingMounts 150`,
`-MirrorExe <path>`, `-DokanNpDll <path>`, `-BinDir <dir>`.

The suite exits non-zero if any test reports FAIL. SKIP means a prerequisite
(driver, mirror, NP dll) was missing for that test.

Warning: the stress tests (`RenameEx-2195`, `MountStorm-2196`) will BSOD the
machine if run against a driver that does not contain the fixes. Run them on
a disposable VM, ideally with Driver Verifier enabled for dokan2.sys.
