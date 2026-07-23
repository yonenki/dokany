// Scaling regression test for textil#2199 (no mount quota) and textil#2205
// (global timeout scanner + DOKAN_OPTIONS.ThreadCount knob).
// - With ThreadCount=1, a single host process must be able to hold far more
//   mounts than the historical ~90-mount ceiling.
// - The runner also derives the kernel-threads-per-mount ratio, which must
//   stay near 2 (notification thread + amortized global threads), not 3+.
#include <stdio.h>
#include <windows.h>

#include "dokan.h"

static NTSTATUS DOKAN_CALLBACK
MmZwCreateFile(LPCWSTR FileName, PDOKAN_IO_SECURITY_CONTEXT SecurityContext,
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
MmGetFileInformation(LPCWSTR FileName, LPBY_HANDLE_FILE_INFORMATION Buffer,
                     PDOKAN_FILE_INFO DokanFileInfo) {
  UNREFERENCED_PARAMETER(FileName);
  UNREFERENCED_PARAMETER(DokanFileInfo);
  ZeroMemory(Buffer, sizeof(*Buffer));
  Buffer->dwFileAttributes = FILE_ATTRIBUTE_NORMAL;
  return STATUS_SUCCESS;
}

static void DOKAN_CALLBACK MmCleanup(LPCWSTR FileName,
                                     PDOKAN_FILE_INFO DokanFileInfo) {
  UNREFERENCED_PARAMETER(FileName);
  UNREFERENCED_PARAMETER(DokanFileInfo);
}

static void DOKAN_CALLBACK MmClose(LPCWSTR FileName,
                                   PDOKAN_FILE_INFO DokanFileInfo) {
  UNREFERENCED_PARAMETER(FileName);
  UNREFERENCED_PARAMETER(DokanFileInfo);
}

// usage: mountmany [count] [threadCount] [holdMs]
int wmain(int argc, wchar_t **argv) {
  int count = argc > 1 ? _wtoi(argv[1]) : 200;
  USHORT threadCount = argc > 2 ? (USHORT)_wtoi(argv[2]) : 1;
  int holdMs = argc > 3 ? _wtoi(argv[3]) : 30000;
  DokanInit();
  int ok = 0, fail = 0;
  for (int i = 0; i < count; i++) {
    WCHAR mnt[MAX_PATH];
    swprintf(mnt, MAX_PATH, L"C:\\mnt\\sectest-q%d", i);
    CreateDirectoryW(mnt, NULL);
    DOKAN_OPTIONS opts;
    DOKAN_OPERATIONS ops;
    ZeroMemory(&opts, sizeof opts);
    ZeroMemory(&ops, sizeof ops);
    opts.Version = DOKAN_VERSION;
    opts.MountPoint = mnt;
    opts.ThreadCount = threadCount;
    ops.ZwCreateFile = MmZwCreateFile;
    ops.GetFileInformation = MmGetFileInformation;
    ops.Cleanup = MmCleanup;
    ops.CloseFile = MmClose;
    DOKAN_HANDLE h = NULL;
    int rc = DokanCreateFileSystem(&opts, &ops, &h);
    if (rc == DOKAN_SUCCESS && h != NULL) {
      ok++;
    } else {
      fail++;
      printf("mount %d failed rc=%d\n", i, rc);
      fflush(stdout);
    }
  }
  printf("final: mounted=%d fail=%d\n", ok, fail);
  fflush(stdout);
  Sleep(holdMs); // keep mounts alive so the runner can measure resources
  return fail == 0 ? 0 : 1;
}
