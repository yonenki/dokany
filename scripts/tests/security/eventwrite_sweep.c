// Regression test for textil#2183: DokanEventWrite dereferenced
// DriverContext[DRIVER_CONTEXT_EVENT] without checking for a pending
// IRP_MJ_WRITE, giving any local user a deterministic BSOD. The event
// channel is now restricted to the file system host process, so this sweep
// must be rejected for every serial number and the machine must survive.
#include <stdio.h>
#include <windows.h>

#include "dokan.h"

#define MY_FSCTL_EVENT_WRITE ((0x0009 << 16) | (0x806 << 2) | 2)

#pragma pack(push, 8)
typedef struct {
  ULONG SerialNumber;
  LONG Status;
  ULONG Flags;
  union {
    struct { ULONG Index; } Directory;
    struct { ULONG Flags; ULONG Information; } Create;
    LARGE_INTEGER Read;
    LARGE_INTEGER Write;
    UCHAR DeletePending;
    ULONG ResetTimeout;
    HANDLE AccessToken;
  } Operation;
  ULONG64 Context;
  ULONG BufferLength;
  ULONG PullEventTimeoutMs;
  UCHAR Buffer[8];
} MY_EVENT_INFORMATION;
#pragma pack(pop)

static DWORD WINAPI SweepOpenThread(LPVOID p) {
  HANDLE h = CreateFileW((LPCWSTR)p, GENERIC_READ,
                         FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         NULL, OPEN_EXISTING, 0, NULL);
  if (h != INVALID_HANDLE_VALUE)
    CloseHandle(h);
  return 0;
}

// usage: eventwrite_sweep [mountpoint] [max-serial]
int wmain(int argc, wchar_t **argv) {
  LPCWSTR mount = argc > 1 ? argv[1] : L"C:\\mnt\\sectest-t2";
  ULONG maxSerial = argc > 2 ? (ULONG)_wtoi(argv[2]) : 20000;
  ULONG n = 0;
  PDOKAN_MOUNT_POINT_INFO list = DokanGetMountPointList(FALSE, &n);
  if (!list) {
    printf("FAIL: DokanGetMountPointList returned nothing\n");
    return 1;
  }
  WCHAR dev[256] = {0};
  size_t ml = wcslen(mount);
  for (ULONG i = 0; i < n; i++) {
    size_t mpl = wcslen(list[i].MountPoint);
    if (mpl >= ml && _wcsicmp(list[i].MountPoint + mpl - ml, mount) == 0)
      swprintf(dev, 256, L"\\\\?\\GLOBALROOT%s", list[i].DeviceName);
  }
  if (!dev[0]) {
    printf("FAIL: mount %ws not found in list\n", mount);
    return 1;
  }

  WCHAR target[MAX_PATH];
  swprintf(target, MAX_PATH, L"%s\\sectest-pending.txt", mount);
  HANDLE th = CreateThread(NULL, 0, SweepOpenThread, target, 0, NULL);
  Sleep(3000); // the FS host pends the create

  HANDLE d = CreateFileW(dev, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                         OPEN_EXISTING, 0, NULL);
  if (d == INVALID_HANDLE_VALUE) {
    printf("FAIL: device open failed %lu\n", GetLastError());
    return 1;
  }
  char out[4096];
  for (ULONG s = 1; s < maxSerial; s++) {
    MY_EVENT_INFORMATION ev;
    ZeroMemory(&ev, sizeof ev);
    ev.SerialNumber = s;
    DWORD ret = 0;
    DeviceIoControl(d, MY_FSCTL_EVENT_WRITE, &ev, sizeof ev, out, sizeof out,
                    &ret, NULL);
  }
  printf("sweep done (SURVIVED)\n");
  CloseHandle(d);
  return 0;
}
