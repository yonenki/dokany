/*
  Dokan : user-mode file system library for Windows

  Copyright (C) 2020 - 2025 Google, Inc.
  Copyright (C) 2015 - 2019 Adrien J. <liryna.stark@gmail.com> and Maxime C. <maxime@islog.com>
  Copyright (C) 2007 - 2011 Hiroki Asakawa <info@dokan-dev.net>

  http://dokan-dev.github.io

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU Lesser General Public License as published by the Free
Software Foundation; either version 3 of the License, or (at your option) any
later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU Lesser General Public License along
with this program. If not, see <http://www.gnu.org/licenses/>.
*/

#include <stdio.h>
#include "dokani.h"

ULONG DOKANAPI DokanVersion() { return DOKAN_VERSION; }

ULONG DOKANAPI DokanDriverVersion() {
  ULONG version = 0;
  ULONG ret = 0;

  if (!SendToDevice(DOKAN_GLOBAL_DEVICE_NAME, FSCTL_GET_VERSION,
                    NULL,          // InputBuffer
                    0,             // InputLength
                    &version,      // OutputBuffer
                    sizeof(ULONG), // OutputLength
                    &ret)) {
    DbgPrintW(L"FSCTL_GET_VERSION failed\n");
    return 0;
  }

  return version;
}

_Success_(return != FALSE)
BOOL DokanQueryRuntimeIdentity(_In_ HANDLE Device,
                               _Out_ PDOKAN_RUNTIME_IDENTITY Identity) {
  DWORD returnedLength = 0;
  if (Device == NULL || Device == INVALID_HANDLE_VALUE || Identity == NULL) {
    SetLastError(ERROR_INVALID_PARAMETER);
    return FALSE;
  }

  ZeroMemory(Identity, sizeof(*Identity));
  if (!DeviceIoControl(Device, FSCTL_GET_RUNTIME_IDENTITY, NULL, 0, Identity,
                       sizeof(*Identity), &returnedLength, NULL)) {
    return FALSE;
  }
  if (returnedLength != sizeof(*Identity) ||
      Identity->Size != sizeof(*Identity)) {
    SetLastError(ERROR_INVALID_DATA);
    return FALSE;
  }
  return TRUE;
}

BOOL DokanIsRuntimeIdentityCompatible(
    _In_ const DOKAN_RUNTIME_IDENTITY *Identity) {
  static const GUID expectedFamilyGuid = DOKAN_DIST_FAMILY_GUID_INITIALIZER;
  static const UCHAR
      expectedProfileHash[DOKAN_RUNTIME_IDENTITY_PROFILE_HASH_SIZE] =
          DOKAN_DIST_PROFILE_HASH_BYTES;

  if (Identity == NULL || Identity->Size != sizeof(*Identity) ||
      Identity->SchemaVersion != DOKAN_DIST_SCHEMA_VERSION ||
      Identity->ProtocolAbi != DOKAN_DIST_PROTOCOL_ABI ||
      !(Identity->Capabilities & DOKAN_DRIVER_CAPABILITY_RUNTIME_IDENTITY) ||
      memcmp(&Identity->FamilyGuid, &expectedFamilyGuid,
             sizeof(expectedFamilyGuid)) != 0 ||
      memcmp(Identity->ProfileHash, expectedProfileHash,
             sizeof(expectedProfileHash)) != 0) {
    SetLastError(ERROR_REVISION_MISMATCH);
    return FALSE;
  }
  return TRUE;
}

_Success_(return != FALSE)
BOOL DOKANAPI DokanGetRuntimeIdentity(
    _Out_ PDOKAN_RUNTIME_IDENTITY Identity) {
  ULONG returnedLength = 0;
  if (Identity == NULL) {
    SetLastError(ERROR_INVALID_PARAMETER);
    return FALSE;
  }
  ZeroMemory(Identity, sizeof(*Identity));
  if (!SendToDevice(DOKAN_GLOBAL_DEVICE_NAME, FSCTL_GET_RUNTIME_IDENTITY, NULL,
                    0, Identity, sizeof(*Identity), &returnedLength)) {
    return FALSE;
  }
  if (returnedLength != sizeof(*Identity) ||
      Identity->Size != sizeof(*Identity)) {
    SetLastError(ERROR_INVALID_DATA);
    return FALSE;
  }
  return TRUE;
}
