/*
  Dokan : user-mode file system library for Windows

  Copyright (C) 2020 - 2025 Google, Inc.
  Copyright (C) 2015 - 2019 Adrien J. <liryna.stark@gmail.com> and Maxime C. <maxime@islog.com>
  Copyright (C) 2007 - 2011 Hiroki Asakawa <info@dokan-dev.net>

  http://dokan-dev.github.io

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/

#include <locale.h>
#include <stdio.h>
#include <stdlib.h>

#include "../dokan/dokan.h"
#include "../dokan/dokanc.h"
#include <ShlObj.h>

#define DOKAN_DRIVER_FULL_PATH DOKAN_DIST_DRIVER_SYSTEM_PATH_W

int ShowUsage() {
  fprintf(stderr,
          "dokanctl /u MountPoint\n"
          "dokanctl /u M\n"
          "dokanctl /i [d|n|a]\n"
          "dokanctl /r [d|n|a]\n"
          "dokanctl /q\n"
          "dokanctl /p\n"
          "dokanctl /v\n"
          "\n"
          "Example:\n"
          "  /u M                : Unmount M: drive\n"
          "  /u C:\\mount\\dokan   : Unmount mount point C:\\mount\\dokan\n"
          "  /i d                : Install driver\n"
          "  /i n                : Install network provider\n"
          "  /r d                : Remove driver\n"
          "  /r n                : Remove network provider\n"
          "  /l a                : List current mount points\n"
          "  /d [0-7]            : Enable Kernel Debug output\n"
          "  /o [n]              : Query (no arg) or set the mount quota (0 = off)\n"
          "  /q                  : Print runtime identity as JSON\n"
          "  /p                  : Prepare driver for service stop\n"
          "  /v                  : Print Dokan version\n");
  return EXIT_FAILURE;
}

int DefaultCaseOption() {
  fprintf(stderr, "Unknown option - Use /? to show usage\n");
  return EXIT_FAILURE;
}

int Unmount(LPCWSTR MountPoint) {
  int status = EXIT_SUCCESS;

  if (!DokanRemoveMountPoint(MountPoint)) {
    status = EXIT_FAILURE;
  }

  fwprintf(stdout, L"Unmount status = %d\n", status);
  return status;
}

int PrintRuntimeIdentity() {
  DOKAN_RUNTIME_IDENTITY identity;
  if (!DokanGetRuntimeIdentity(&identity)) {
    fprintf(stderr, "Failed to query runtime identity: %lu\n", GetLastError());
    return EXIT_FAILURE;
  }

  fprintf(stdout,
          "{\"schemaVersion\":%lu,\"protocolAbi\":%lu,"
          "\"driverVersion\":%lu,\"capabilities\":\"0x%016I64x\","
          "\"familyGuid\":\"%08lX-%04hX-%04hX-"
          "%02hhX%02hhX-%02hhX%02hhX%02hhX%02hhX%02hhX%02hhX\","
          "\"profileHash\":\"",
          identity.SchemaVersion, identity.ProtocolAbi, identity.DriverVersion,
          identity.Capabilities, identity.FamilyGuid.Data1,
          identity.FamilyGuid.Data2, identity.FamilyGuid.Data3,
          identity.FamilyGuid.Data4[0], identity.FamilyGuid.Data4[1],
          identity.FamilyGuid.Data4[2], identity.FamilyGuid.Data4[3],
          identity.FamilyGuid.Data4[4], identity.FamilyGuid.Data4[5],
          identity.FamilyGuid.Data4[6], identity.FamilyGuid.Data4[7]);
  for (size_t index = 0; index < DOKAN_RUNTIME_IDENTITY_PROFILE_HASH_SIZE;
       ++index) {
    fprintf(stdout, "%02x", identity.ProfileHash[index]);
  }
  fprintf(stdout, "\"}\n");
  return EXIT_SUCCESS;
}

int InstallDriver(LPCWSTR driverFullPath) {
  fprintf(stdout, "Installing driver...\n");
  if (GetFileAttributes(driverFullPath) == INVALID_FILE_ATTRIBUTES) {
    fwprintf(stderr, L"Error the file '%ls' does not exist.\n", driverFullPath);
    return EXIT_FAILURE;
  }

  if (!DokanServiceInstall(DOKAN_DRIVER_SERVICE, SERVICE_FILE_SYSTEM_DRIVER,
                           DOKAN_DRIVER_FULL_PATH)) {
    fprintf(stderr, "Driver install failed\n");
    return EXIT_FAILURE;
  }

  fprintf(stdout, "Driver installation succeeded!\n");
  return EXIT_SUCCESS;
}

int DeleteDokanService(LPCWSTR ServiceName) {
  fwprintf(stdout, L"Removing '%ls'...\n", ServiceName);
  if (!DokanServiceDelete(ServiceName)) {
    fwprintf(stderr, L"Error removing '%ls'\n", ServiceName);
    return EXIT_FAILURE;
  }
  fwprintf(stdout, L"'%ls' removed.\n", ServiceName);
  return EXIT_SUCCESS;
}

#define GetOption(argc, argv, index)                                           \
  (((argc) > (index) && wcslen((argv)[(index)]) == 2 &&                        \
    (argv)[(index)][0] == L'/')                                                \
       ? towlower((argv)[(index)][1])                                          \
       : L'\0')

int __cdecl wmain(int argc, PWCHAR argv[]) {
  size_t i;
  WCHAR fileName[MAX_PATH];
  WCHAR driverFullPath[MAX_PATH] = {0};
  PVOID wow64OldValue;
  BOOL isAdmin;

  isAdmin = IsUserAnAdmin();

  DokanUseStdErr(TRUE); // Set dokan library debug output

  Wow64DisableWow64FsRedirection(&wow64OldValue); // Disable system32 direct
  // setlocale(LC_ALL, "");

  GetModuleFileName(NULL, fileName, MAX_PATH);

  // search the last "\"
  for (i = wcslen(fileName) - 1; i > 0 && fileName[i] != L'\\'; --i) {
    ;
  }
  fileName[i] = L'\0';

  ExpandEnvironmentStringsW(DOKAN_DRIVER_FULL_PATH, driverFullPath, MAX_PATH);

  WCHAR option = GetOption(argc, argv, 1);
  if (option == L'\0' || option == L'?') {
    return ShowUsage();
  }

  if (!isAdmin &&
      (option == L'i' || option == L'r' || option == L'd' || option == L'u' ||
       option == L'p')) {
    fprintf(stderr, "Admin rights required to process this operation\n");
    return EXIT_FAILURE;
  }

  if (option == L'i') {
    fwprintf(stdout, L"Driver path: '%ls'\n", driverFullPath);
  }

  switch (option) {
  // Admin rights required
  case L'i': {
    if (argc < 3) {
      return DefaultCaseOption();
    }
    WCHAR type = towlower(argv[2][0]);
    int result = EXIT_SUCCESS;
    if (type != L'd' && type != L'n' && type != L'a') {
      return DefaultCaseOption();
    }
    if (type == L'd' || type == L'a') {
      result = InstallDriver(driverFullPath);
    }
    if (result != EXIT_SUCCESS || (type != L'n' && type != L'a')) {
      return result;
    }
    if (DokanNetworkProviderInstall()) {
      fprintf(stdout, "Network provider install ok\n");
    } else {
      fprintf(stderr, "Network provider install failed\n");
      result = EXIT_FAILURE;
    }
    return result;
  }

  case L'r': {
    if (argc < 3) {
      return DefaultCaseOption();
    }
    WCHAR type = towlower(argv[2][0]);
    int result = EXIT_SUCCESS;
    if (type != L'd' && type != L'n' && type != L'a') {
      return DefaultCaseOption();
    }
    if (type == L'd' || type == L'a') {
      result = DeleteDokanService(DOKAN_DRIVER_SERVICE);
    }
    if (result != EXIT_SUCCESS || (type != L'n' && type != L'a')) {
      return result;
    }
    if (DokanNetworkProviderUninstall()) {
      fprintf(stdout, "Network provider remove ok\n");
    } else {
      fprintf(stderr, "Network provider remove failed\n");
      result = EXIT_FAILURE;
    }
    return result;
  }

  case L'd': {
    if (argc < 3) {
      return DefaultCaseOption();
    }
    WCHAR type = towlower(argv[2][0]);
    if (L'0' > type || type > L'7')
      return DefaultCaseOption();

    ULONG mode = type - L'0';
    if (DokanSetDebugMode(mode)) {
      fprintf(stdout, "set debug mode ok\n");
    } else {
      fprintf(stderr, "set debug mode failed\n");
      return EXIT_FAILURE;
    }
  } break;

  case L'o': {
    if (argc < 3) {
      LONG quota = 0;
      if (DokanGetMountQuota(&quota)) {
        fwprintf(stdout, L"Mount quota: %ld\n", quota);
      } else {
        fwprintf(stderr, L"Failed to query mount quota: %lu\n", GetLastError());
        return EXIT_FAILURE;
      }
    } else {
      LONG quota = _wtol(argv[2]);
      if (quota < 0) {
        return DefaultCaseOption();
      }
      if (DokanSetMountQuota(quota)) {
        fwprintf(stdout, L"Mount quota set to %ld\n", quota);
      } else {
        fwprintf(stderr, L"Failed to set mount quota: %lu\n", GetLastError());
        return EXIT_FAILURE;
      }
    }
  } break;

  case L'u': {
    if (argc < 3) {
      return DefaultCaseOption();
    }
    return Unmount(argv[2]);
  }

  // No admin rights required
  case L'l': {
    ULONG nbRead = 0;
    PDOKAN_MOUNT_POINT_INFO dokanMountPointInfo =
        DokanGetMountPointList(FALSE, &nbRead);
    if (dokanMountPointInfo == NULL) {
      fwprintf(stderr, L"  Cannot retrieve mount point list.\n");
      return EXIT_FAILURE;
    }

    fwprintf(stdout, L"  Mount points: %lu\n", nbRead);
    for (ULONG p = 0; p < nbRead; ++p)
      fwprintf(stdout, L"  %lu# MountPoint: %ls - UNC: %ls - DeviceName: %ls\n",
               p, dokanMountPointInfo[p].MountPoint,
               dokanMountPointInfo[p].UNCName,
               dokanMountPointInfo[p].DeviceName);
    DokanReleaseMountPointList(dokanMountPointInfo);
  } break;

  case L'q':
    return PrintRuntimeIdentity();

  case L'p': {
    if (DokanPrepareDriverUnload()) {
      fprintf(stdout, "Driver is prepared for service stop\n");
      return EXIT_SUCCESS;
    }
    DWORD error = GetLastError();
    fprintf(stderr, "Driver unload preparation failed: %lu\n", error);
    return error == ERROR_BUSY ? ERROR_BUSY : EXIT_FAILURE;
  }

  case L'v': {
    fprintf(stdout, "dokanctl : %s %s\n", __DATE__, __TIME__);
    fprintf(stdout, "Dokan version : %ld\n", DokanVersion());
    fprintf(stdout, "Dokan driver version : 0x%lx\n", DokanDriverVersion());
  } break;

  default:
    return DefaultCaseOption();
  }

  return EXIT_SUCCESS;
}
