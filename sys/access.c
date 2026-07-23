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

#include "dokan.h"
#include "util/irp_buffer_helper.h"

NTSTATUS
DokanGetAccessToken(__in PREQUEST_CONTEXT RequestContext) {
  KIRQL oldIrql = 0;
  PLIST_ENTRY thisEntry, nextEntry, listHead;
  PIRP_ENTRY irpEntry;
  PEVENT_INFORMATION eventInfo = NULL;
  PACCESS_TOKEN accessToken = NULL;
  NTSTATUS status = STATUS_INVALID_PARAMETER;
  HANDLE handle;
  BOOLEAN hasLock = FALSE;
  ULONG outBufferLen;

  __try {

    if (RequestContext->Irp->RequestorMode != UserMode) {
      DOKAN_LOG_FINE_IRP(RequestContext, "Needs to be called from user-mode");
      status = STATUS_INVALID_PARAMETER;
      __leave;
    }

    GET_IRP_BUFFER_OR_LEAVE(RequestContext->Irp, eventInfo);
    outBufferLen =
        RequestContext->IrpSp->Parameters.DeviceIoControl.OutputBufferLength;
    if (outBufferLen != sizeof(EVENT_INFORMATION)) {
      DOKAN_LOG_FINE_IRP(RequestContext, "Wrong output buffer length");
      status = STATUS_INVALID_PARAMETER;
      __leave;
    }

    ASSERT(KeGetCurrentIrql() <= DISPATCH_LEVEL);
    KeAcquireSpinLock(&RequestContext->Dcb->PendingIrp.ListLock, &oldIrql);
    hasLock = TRUE;

    // search corresponding IRP through pending IRP list
    listHead = &RequestContext->Dcb->PendingIrp.ListHead;

    for (thisEntry = listHead->Flink; thisEntry != listHead;
         thisEntry = nextEntry) {

      nextEntry = thisEntry->Flink;

      irpEntry = CONTAINING_RECORD(thisEntry, IRP_ENTRY, ListEntry);

      if (irpEntry->SerialNumber != eventInfo->SerialNumber) {
        continue;
      }

      // Only IRP_MJ_CREATE carries a valid PIO_SECURITY_CONTEXT here. For
      // any other pending IRP type the same union storage holds unrelated,
      // caller-controlled values (e.g. Read/Write ByteOffset) which must
      // never be dereferenced as pointers.
      if (irpEntry->RequestContext.IrpSp->MajorFunction != IRP_MJ_CREATE) {
        status = STATUS_INVALID_PARAMETER;
        break;
      }

      PIO_SECURITY_CONTEXT securityContext =
          irpEntry->RequestContext.IrpSp->Parameters.Create.SecurityContext;
      if (securityContext != NULL) {
        PACCESS_STATE accessState = securityContext->AccessState;
        if (accessState != NULL) {
          accessToken =
              SeQuerySubjectContextToken(&accessState->SubjectSecurityContext);
        }
      }
      if (accessToken != NULL) {
        // Pin the token while the pending IRP is still protected by the list
        // lock so that it stays valid after the lock is released below.
        // Without this, the IRP could complete and free the access state in
        // between.
        ObReferenceObject(accessToken);
      } else {
        status = STATUS_INVALID_PARAMETER;
      }
      break;
    }
    KeReleaseSpinLock(&RequestContext->Dcb->PendingIrp.ListLock, oldIrql);
    hasLock = FALSE;

    if (accessToken == NULL) {
      DOKAN_LOG_FINE_IRP(RequestContext, "Can't find pending create Irp: %ld",
                         eventInfo->SerialNumber);
      __leave;
    }

    // NOTE: Accessing *SeTokenObjectType while acquring sping lock causes
    // BSOD on Windows XP.
    // The granted access is limited to what a file system host needs to
    // inspect and impersonate the requestor, instead of GENERIC_ALL.
    status = ObOpenObjectByPointer(
        accessToken, 0, NULL, TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_IMPERSONATE,
        *SeTokenObjectType, KernelMode, &handle);
    ObDereferenceObject(accessToken);
    if (!NT_SUCCESS(status)) {
      DOKAN_LOG_FINE_IRP(RequestContext,
                         "ObOpenObjectByPointer failed: 0x%x %s", status,
                         DokanGetNTSTATUSStr(status));
      __leave;
    }

    eventInfo->Operation.AccessToken.Handle = handle;
    RequestContext->Irp->IoStatus.Information = sizeof(EVENT_INFORMATION);
    status = STATUS_SUCCESS;

  } __finally {
    if (hasLock) {
      KeReleaseSpinLock(&RequestContext->Dcb->PendingIrp.ListLock, oldIrql);
    }
  }
  return status;
}
