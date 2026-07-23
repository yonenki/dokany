// FS host used by the event-channel regression tests (textil#2183/#2184).
// Mounts a volume and pends every ZwCreateFile for 120 seconds so that a
// pending IRP_MJ_CREATE with a live serial number always exists while the
// test sweeps serial numbers from another process.
#include <stdio.h>
#include <windows.h>

#include "dokan.h"

static NTSTATUS DOKAN_CALLBACK
HostZwCreateFile(LPCWSTR FileName, PDOKAN_IO_SECURITY_CONTEXT SecurityContext,
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
  Sleep(120000);
  return STATUS_SUCCESS;
}

static NTSTATUS DOKAN_CALLBACK
HostGetFileInformation(LPCWSTR FileName, LPBY_HANDLE_FILE_INFORMATION Buffer,
                       PDOKAN_FILE_INFO DokanFileInfo) {
  UNREFERENCED_PARAMETER(FileName);
  UNREFERENCED_PARAMETER(DokanFileInfo);
  ZeroMemory(Buffer, sizeof(*Buffer));
  Buffer->dwFileAttributes = FILE_ATTRIBUTE_NORMAL;
  return STATUS_SUCCESS;
}

static void DOKAN_CALLBACK HostCleanup(LPCWSTR FileName,
                                       PDOKAN_FILE_INFO DokanFileInfo) {
  UNREFERENCED_PARAMETER(FileName);
  UNREFERENCED_PARAMETER(DokanFileInfo);
}

static void DOKAN_CALLBACK HostClose(LPCWSTR FileName,
                                     PDOKAN_FILE_INFO DokanFileInfo) {
  UNREFERENCED_PARAMETER(FileName);
  UNREFERENCED_PARAMETER(DokanFileInfo);
}

// usage: eventwrite_fshost [mountpoint]
int wmain(int argc, wchar_t **argv) {
  DOKAN_OPTIONS opts;
  DOKAN_OPERATIONS ops;
  ZeroMemory(&opts, sizeof opts);
  ZeroMemory(&ops, sizeof ops);
  opts.Version = DOKAN_VERSION;
  opts.MountPoint = argc > 1 ? argv[1] : L"C:\\mnt\\sectest-t2";
  ops.ZwCreateFile = HostZwCreateFile;
  ops.GetFileInformation = HostGetFileInformation;
  ops.Cleanup = HostCleanup;
  ops.CloseFile = HostClose;
  CreateDirectoryW(opts.MountPoint, NULL);
  DokanInit();
  return DokanMain(&opts, &ops);
}
