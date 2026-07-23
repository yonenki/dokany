// Stress regression test for textil#2196: concurrent unmounts of different
// devices used to corrupt the global DeviceDeleteList (BSOD 0x139). Each
// thread mounts and unmounts its own volume in-process to maximize teardown
// concurrency. On a fixed driver the storm completes; on a buggy driver the
// machine bugchecks inside InsertDeviceToDelete.
#include <stdio.h>
#include <windows.h>

#include "dokan.h"

static volatile LONG g_stop = 0;
static volatile LONG g_cycles = 0;

static NTSTATUS DOKAN_CALLBACK
MsZwCreateFile(LPCWSTR FileName, PDOKAN_IO_SECURITY_CONTEXT SecurityContext,
               ACCESS_MASK DesiredAccess, ULONG FileAttributes,
               ULONG ShareAccess, ULONG CreateDisposition, ULONG CreateOptions,
               PDOKAN_FILE_INFO DokanFileInfo) {
  UNREFERENCED_PARAMETER(SecurityContext);
  UNREFERENCED_PARAMETER(DesiredAccess);
  UNREFERENCED_PARAMETER(FileAttributes);
  UNREFERENCED_PARAMETER(ShareAccess);
  UNREFERENCED_PARAMETER(CreateDisposition);
  UNREFERENCED_PARAMETER(CreateOptions);
  UNREFERENCED_PARAMETER(DokanFileInfo);
  UNREFERENCED_PARAMETER(FileName);
  return STATUS_SUCCESS;
}

static NTSTATUS DOKAN_CALLBACK
MsGetFileInformation(LPCWSTR FileName, LPBY_HANDLE_FILE_INFORMATION Buffer,
                     PDOKAN_FILE_INFO DokanFileInfo) {
  UNREFERENCED_PARAMETER(FileName);
  UNREFERENCED_PARAMETER(DokanFileInfo);
  ZeroMemory(Buffer, sizeof(*Buffer));
  Buffer->dwFileAttributes = FILE_ATTRIBUTE_NORMAL;
  return STATUS_SUCCESS;
}

static void DOKAN_CALLBACK MsCleanup(LPCWSTR FileName,
                                     PDOKAN_FILE_INFO DokanFileInfo) {
  UNREFERENCED_PARAMETER(FileName);
  UNREFERENCED_PARAMETER(DokanFileInfo);
}

static void DOKAN_CALLBACK MsClose(LPCWSTR FileName,
                                   PDOKAN_FILE_INFO DokanFileInfo) {
  UNREFERENCED_PARAMETER(FileName);
  UNREFERENCED_PARAMETER(DokanFileInfo);
}

static DWORD WINAPI MountLoop(LPVOID p) {
  int id = (int)(ULONG_PTR)p;
  WCHAR mnt[MAX_PATH];
  swprintf(mnt, MAX_PATH, L"C:\\mnt\\sectest-ms%d", id);
  CreateDirectoryW(mnt, NULL);
  while (!g_stop) {
    DOKAN_OPTIONS opts;
    DOKAN_OPERATIONS ops;
    ZeroMemory(&opts, sizeof opts);
    ZeroMemory(&ops, sizeof ops);
    opts.Version = DOKAN_VERSION;
    opts.MountPoint = mnt;
    ops.ZwCreateFile = MsZwCreateFile;
    ops.GetFileInformation = MsGetFileInformation;
    ops.Cleanup = MsCleanup;
    ops.CloseFile = MsClose;
    DOKAN_HANDLE h = NULL;
    int rc = DokanCreateFileSystem(&opts, &ops, &h);
    if (rc != DOKAN_SUCCESS || h == NULL) {
      Sleep(100);
      continue;
    }
    DokanRemoveMountPoint(mnt);
    DokanCloseHandle(h);
    InterlockedIncrement(&g_cycles);
  }
  return 0;
}

// usage: mountstorm [threads] [seconds]
int wmain(int argc, wchar_t **argv) {
  int threads = argc > 1 ? _wtoi(argv[1]) : 8;
  int seconds = argc > 2 ? _wtoi(argv[2]) : 60;
  DokanInit();
  HANDLE th[32];
  for (int i = 0; i < threads && i < 32; i++)
    th[i] = CreateThread(NULL, 0, MountLoop, (LPVOID)(ULONG_PTR)i, 0, NULL);
  Sleep(seconds * 1000);
  InterlockedExchange(&g_stop, 1);
  WaitForMultipleObjects(threads, th, TRUE, 60000);
  printf("done cycles=%ld\n", g_cycles);
  return g_cycles > 0 ? 0 : 1;
}
