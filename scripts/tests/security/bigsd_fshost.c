// FS host for the textil#2185 regression test. Reports a 60KB security
// descriptor so that the library must answer STATUS_BUFFER_OVERFLOW with a
// header-only reply; a buggy library ships FIELD_OFFSET + lengthNeeded bytes
// from a ~48 byte allocation and kills the volume.
#include <stdio.h>
#include <windows.h>

#include "dokan.h"

static NTSTATUS DOKAN_CALLBACK
SdZwCreateFile(LPCWSTR FileName, PDOKAN_IO_SECURITY_CONTEXT SecurityContext,
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
SdGetFileInformation(LPCWSTR FileName, LPBY_HANDLE_FILE_INFORMATION Buffer,
                     PDOKAN_FILE_INFO DokanFileInfo) {
  UNREFERENCED_PARAMETER(FileName);
  UNREFERENCED_PARAMETER(DokanFileInfo);
  ZeroMemory(Buffer, sizeof(*Buffer));
  Buffer->dwFileAttributes = FILE_ATTRIBUTE_NORMAL;
  return STATUS_SUCCESS;
}

static NTSTATUS DOKAN_CALLBACK
SdGetFileSecurity(LPCWSTR FileName, PSECURITY_INFORMATION SecurityInformation,
                  PSECURITY_DESCRIPTOR SecurityDescriptor,
                  ULONG SecurityDescriptorLength, PULONG LengthNeeded,
                  PDOKAN_FILE_INFO DokanFileInfo) {
  UNREFERENCED_PARAMETER(FileName);
  UNREFERENCED_PARAMETER(SecurityInformation);
  UNREFERENCED_PARAMETER(SecurityDescriptor);
  UNREFERENCED_PARAMETER(SecurityDescriptorLength);
  UNREFERENCED_PARAMETER(DokanFileInfo);
  *LengthNeeded = 60000; // large SD, e.g. big AD ACLs
  return STATUS_BUFFER_OVERFLOW;
}

static void DOKAN_CALLBACK SdCleanup(LPCWSTR FileName,
                                     PDOKAN_FILE_INFO DokanFileInfo) {
  UNREFERENCED_PARAMETER(FileName);
  UNREFERENCED_PARAMETER(DokanFileInfo);
}

static void DOKAN_CALLBACK SdClose(LPCWSTR FileName,
                                   PDOKAN_FILE_INFO DokanFileInfo) {
  UNREFERENCED_PARAMETER(FileName);
  UNREFERENCED_PARAMETER(DokanFileInfo);
}

// usage: bigsd_fshost [mountpoint]
int wmain(int argc, wchar_t **argv) {
  DOKAN_OPTIONS opts;
  DOKAN_OPERATIONS ops;
  ZeroMemory(&opts, sizeof opts);
  ZeroMemory(&ops, sizeof ops);
  opts.Version = DOKAN_VERSION;
  opts.MountPoint = argc > 1 ? argv[1] : L"C:\\mnt\\sectest-t3";
  ops.ZwCreateFile = SdZwCreateFile;
  ops.GetFileInformation = SdGetFileInformation;
  ops.GetFileSecurity = SdGetFileSecurity;
  ops.Cleanup = SdCleanup;
  ops.CloseFile = SdClose;
  CreateDirectoryW(opts.MountPoint, NULL);
  DokanInit();
  return DokanMain(&opts, &ops);
}
