// Regression test for textil#2185: tiny security queries must be answered
// with STATUS_BUFFER_TOO_SMALL and the real needed size, and the volume must
// stay mounted afterwards (a buggy library over-read the host heap and the
// volume was dirty-unmounted).
#include <stdio.h>
#include <windows.h>

typedef NTSTATUS(NTAPI *PNtQuerySecurityObject)(HANDLE, SECURITY_INFORMATION,
                                                PSECURITY_DESCRIPTOR, ULONG,
                                                PULONG);

// usage: query_sec <file>
int wmain(int argc, wchar_t **argv) {
  HANDLE h = CreateFileW(argv[1], READ_CONTROL,
                         FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         NULL, OPEN_EXISTING, 0, NULL);
  if (h == INVALID_HANDLE_VALUE) {
    printf("FAIL: open %lu\n", GetLastError());
    return 1;
  }
  PNtQuerySecurityObject NtQuerySecurityObject =
      (PNtQuerySecurityObject)GetProcAddress(GetModuleHandleW(L"ntdll"),
                                             "NtQuerySecurityObject");
  ULONG needed = 0;
  UCHAR sd[8];
  SECURITY_INFORMATION si = OWNER_SECURITY_INFORMATION |
                            GROUP_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION;
  NTSTATUS st = NtQuerySecurityObject(h, si, sd, 0, &needed);
  printf("len=0   st=0x%08lx needed=%lu\n", (unsigned long)st, needed);
  st = NtQuerySecurityObject(h, si, sd, 1, &needed);
  printf("len=1   st=0x%08lx needed=%lu\n", (unsigned long)st, needed);
  st = NtQuerySecurityObject(h, si, sd, 4, &needed);
  printf("len=4   st=0x%08lx needed=%lu\n", (unsigned long)st, needed);
  CloseHandle(h);
  // Expected by the runner: every status is 0xc0000023 and needed is stable.
  return 0;
}
