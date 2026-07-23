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
#include "util/str.h"

VOID DokanUnmount(__in_opt PREQUEST_CONTEXT RequestContext, __in PDokanDCB Dcb) {
  PDokanVCB vcb = Dcb->Vcb;

  DOKAN_LOG("Start");
  if (vcb) {
    DokanEventRelease(RequestContext, vcb->DeviceObject);
  }
  DOKAN_LOG("End");
}

// Scans the pending IRP list for timed out IRPs and completes them.
// Returns TRUE when the volume asks to be unmounted (keepalive not yet
// active and some operation timed out). The caller is responsible for
// performing the unmount once it is safe to do so.
BOOLEAN
ReleaseTimeoutPendingIrp(__in PDokanDCB Dcb) {
  KIRQL oldIrql;
  PLIST_ENTRY thisEntry, nextEntry, listHead;
  PIRP_ENTRY irpEntry;
  LARGE_INTEGER tickCount;
  LIST_ENTRY completeList;
  PIRP irp;
  BOOLEAN shouldUnmount = FALSE;
  PDokanVCB vcb = Dcb->Vcb;
  DOKAN_INIT_LOGGER(logger, Dcb->DeviceObject->DriverObject, 0);

  DOKAN_LOG("Start");
  InitializeListHead(&completeList);

  ASSERT(KeGetCurrentIrql() <= DISPATCH_LEVEL);
  KeAcquireSpinLock(&Dcb->PendingIrp.ListLock, &oldIrql);

  // when IRP queue is empty, there is nothing to do
  if (IsListEmpty(&Dcb->PendingIrp.ListHead)) {
    KeReleaseSpinLock(&Dcb->PendingIrp.ListLock, oldIrql);
    DOKAN_LOG("IrpQueue is Empty");
    return FALSE;
  }

  KeQueryTickCount(&tickCount);

  // search timeout IRP through pending IRP list
  listHead = &Dcb->PendingIrp.ListHead;

  for (thisEntry = listHead->Flink; thisEntry != listHead;
       thisEntry = nextEntry) {

    nextEntry = thisEntry->Flink;

    irpEntry = CONTAINING_RECORD(thisEntry, IRP_ENTRY, ListEntry);

    // If an async operation (like an oplock break or CancelIoEx call from user
    // mode) has set the AsyncStatus to a failure status, then we clean up that
    // IRP as if it had timed out but use the status. The normal way an IRP gets
    // timed out is by its TickCount being too long ago. Continuing here means
    // the IRP is not eligible for cleanup in either way.
    if (irpEntry->AsyncStatus == STATUS_SUCCESS &&
        tickCount.QuadPart < irpEntry->TickCount.QuadPart) {
      continue;
    }

    RemoveEntryList(thisEntry);

    DOKAN_LOG_("Timeout Irp %ld", irpEntry->SerialNumber);

    irp = irpEntry->RequestContext.Irp;

    // Create IRPs (ForcedCanceled) are special in that this routine is always
    // their place of effective cancellation. So we only care about races with
    // the cancel routine for other IRPs (which can be effectively canceled in
    // either place).
    if (!irpEntry->RequestContext.ForcedCanceled) {
      if (irp == NULL) {
        // Already canceled previously.
        ASSERT(irpEntry->CancelRoutineFreeMemory == FALSE);
        DokanFreeIrpEntry(irpEntry);
        continue;
      }
      if (IoSetCancelRoutine(irp, NULL) == NULL) {
        // Cancel routine is already destined to run.
        InitializeListHead(&irpEntry->ListEntry);
        irpEntry->CancelRoutineFreeMemory = TRUE;
        continue;
      }
    } else {
      // Cleanup ForcedCanceled IRP of the attached CancelRoutine before
      // Completion.
      IoSetCancelRoutine(irp, NULL);
    }

    // Prevent possible future runs of the cancel routine from doing anything.
    irp->Tail.Overlay.DriverContext[DRIVER_CONTEXT_IRP_ENTRY] = NULL;

    InsertTailList(&completeList, &irpEntry->ListEntry);
  }

  if (IsListEmpty(&Dcb->PendingIrp.ListHead)) {
    KeClearEvent(&Dcb->PendingIrp.NotEmpty);
  }
  KeReleaseSpinLock(&Dcb->PendingIrp.ListLock, oldIrql);

  shouldUnmount =
      vcb != NULL && !vcb->IsKeepaliveActive && !IsListEmpty(&completeList);
  while (!IsListEmpty(&completeList)) {
    listHead = RemoveHeadList(&completeList);
    irpEntry = CONTAINING_RECORD(listHead, IRP_ENTRY, ListEntry);
    irp = irpEntry->RequestContext.Irp;
    PIO_STACK_LOCATION irpSp = irpEntry->RequestContext.IrpSp;
    DOKAN_LOG_(
        "Cancel [%s][%s] FileObject=%p",
        DokanGetMajorFunctionStr(irpSp->MajorFunction),
        DokanGetMinorFunctionStr(irpSp->MajorFunction, irpSp->MinorFunction),
        irpSp->FileObject);
    if (irpSp->MajorFunction == IRP_MJ_CREATE) {
      BOOLEAN canceled = (irpEntry->TickCount.QuadPart == 0);
      PFILE_OBJECT fileObject = irpEntry->RequestContext.IrpSp->FileObject;
      if (fileObject != NULL) {
        PDokanCCB ccb = fileObject->FsContext2;
        if (ccb != NULL) {
          PDokanFCB fcb = ccb->Fcb;
          OplockDebugRecordFlag(fcb, canceled
                                         ? DOKAN_OPLOCK_DEBUG_CANCELED_CREATE
                                         : DOKAN_OPLOCK_DEBUG_TIMED_OUT_CREATE);
        }
      }
      DokanCancelCreateIrp(&irpEntry->RequestContext,
                           canceled ? STATUS_CANCELLED
                                    : STATUS_INSUFFICIENT_RESOURCES);
    } else {
      if (irpSp->MajorFunction == IRP_MJ_CLEANUP) {
        DokanExecuteCleanup(&irpEntry->RequestContext);
      }
      irp->IoStatus.Information = 0;
      DokanCompleteIrpRequest(irp, STATUS_INSUFFICIENT_RESOURCES);
    }
    DokanFreeIrpEntry(irpEntry);
  }

  if (shouldUnmount) {
    // This avoids a race condition where the app terminates before activating
    // the keepalive handle. In that case, we unmount the file system as soon
    // as some specific operation gets timed out, which avoids repeated delays
    // in Explorer. The actual unmount is performed by the caller once it is
    // no longer holding the global lock.
    DokanLogInfo(
        &logger,
        L"Requesting unmount due to operation timeout before keepalive handle"
        L" was activated.");
  }

  DOKAN_LOG("End");

  return shouldUnmount;
}

NTSTATUS
DokanResetPendingIrpTimeout(__in PREQUEST_CONTEXT RequestContext) {
  KIRQL oldIrql;
  PLIST_ENTRY thisEntry, nextEntry, listHead;
  PIRP_ENTRY irpEntry;
  PEVENT_INFORMATION eventInfo = NULL;
  ULONG timeout; // in milisecond

  GET_IRP_BUFFER_OR_RETURN(RequestContext->Irp, eventInfo);

  timeout = eventInfo->Operation.ResetTimeout.Timeout;
  if (DOKAN_IRP_PENDING_TIMEOUT_RESET_MAX < timeout) {
    timeout = DOKAN_IRP_PENDING_TIMEOUT_RESET_MAX;
  }

  ASSERT(KeGetCurrentIrql() <= DISPATCH_LEVEL);
  KeAcquireSpinLock(&RequestContext->Dcb->PendingIrp.ListLock, &oldIrql);

  // search corresponding IRP through pending IRP list
  listHead = &RequestContext->Dcb->PendingIrp.ListHead;

  for (thisEntry = listHead->Flink; thisEntry != listHead;
       thisEntry = nextEntry) {

    nextEntry = thisEntry->Flink;

    irpEntry = CONTAINING_RECORD(thisEntry, IRP_ENTRY, ListEntry);

    if (irpEntry->SerialNumber != eventInfo->SerialNumber) {
      continue;
    }

    DokanUpdateTimeout(&irpEntry->TickCount, timeout);
    break;
  }
  KeReleaseSpinLock(&RequestContext->Dcb->PendingIrp.ListLock, oldIrql);
  return STATUS_SUCCESS;
}

KSTART_ROUTINE DokanTimeoutScanThread;
VOID DokanTimeoutScanThread(PVOID Context)
/*++

Routine Description:

        Global IRP timeout scanner. One thread for the whole driver that
        checks pending IRPs of every mounted DCB each DOKAN_CHECK_INTERVAL,
        instead of having one such thread per mount.

--*/
{
  NTSTATUS status;
  KTIMER timer;
  PVOID pollevents[3];
  LARGE_INTEGER timeout = {0};
  BOOLEAN waitObj = TRUE;
  LARGE_INTEGER LastTime = {0};
  LARGE_INTEGER CurrentTime = {0};
  PDOKAN_GLOBAL dokanGlobal = Context;
  DOKAN_INIT_LOGGER(logger, dokanGlobal->DeviceObject->DriverObject, 0);

  // How many unmount requests can be deferred per scan tick. Leftover
  // requests are picked up again on the next tick.
  enum { MAX_DEFERRED_UNMOUNTS = 64 };

  DOKAN_LOG("Start");

  KeInitializeTimerEx(&timer, SynchronizationTimer);

  pollevents[0] = (PVOID)&dokanGlobal->TimeoutScanKillEvent;
  pollevents[1] = (PVOID)&dokanGlobal->TimeoutScanForceEvent;
  pollevents[2] = (PVOID)&timer;

  KeSetTimerEx(&timer, timeout, DOKAN_CHECK_INTERVAL, NULL);

  KeQuerySystemTime(&LastTime);

  while (waitObj) {
    status = KeWaitForMultipleObjects(3, pollevents, WaitAny, Executive,
                                      KernelMode, FALSE, NULL, NULL);

    if (!NT_SUCCESS(status) || status == STATUS_WAIT_0) {
      DOKAN_LOG("DokanTimeoutScanThread catched KillEvent");
      // KillEvent or something error is occurred
      waitObj = FALSE;
      continue;
    }

    KeClearEvent(&dokanGlobal->TimeoutScanForceEvent);
    // In this case the timer was executed and we are checking if the timer
    // occurred regulary using the period DOKAN_CHECK_INTERVAL. If not, this
    // means the system was in sleep mode.
    KeQuerySystemTime(&CurrentTime);
    if ((CurrentTime.QuadPart - LastTime.QuadPart) >
        ((DOKAN_CHECK_INTERVAL + 2000) * 10000)) {
      DokanLogInfo(&logger, L"Wake from sleep detected.");
    } else {
      PDEVICE_OBJECT unmountDevices[MAX_DEFERRED_UNMOUNTS];
      ULONG unmountCount = 0;

      // Scan every mounted DCB. The list is protected by the global Resource
      // held shared; the delete worker frees DCBs only while holding it
      // exclusively, so scanned DCBs cannot die under us. Unmount requests
      // are deferred because DokanEventRelease needs the same Resource
      // exclusively.
      ExAcquireResourceSharedLite(&dokanGlobal->Resource, TRUE);
      for (PLIST_ENTRY entry = dokanGlobal->AllDcbList.Flink;
           entry != &dokanGlobal->AllDcbList; entry = entry->Flink) {
        PDokanDCB dcb = CONTAINING_RECORD(entry, DokanDCB, AllDcbListEntry);
        if (ReleaseTimeoutPendingIrp(dcb) &&
            unmountCount < MAX_DEFERRED_UNMOUNTS) {
          // Keep the disk device (and therefore the DCB extension) alive
          // until the unmount is issued below.
          ObReferenceObject(dcb->DeviceObject);
          unmountDevices[unmountCount++] = dcb->DeviceObject;
        }
      }
      ExReleaseResourceLite(&dokanGlobal->Resource);

      for (ULONG i = 0; i < unmountCount; ++i) {
        PDokanDCB dcb = unmountDevices[i]->DeviceExtension;
        DokanUnmount(NULL, dcb);
        ObDereferenceObject(unmountDevices[i]);
      }
    }
    KeQuerySystemTime(&LastTime);
  }

  KeCancelTimer(&timer);

  DOKAN_LOG("Stop");

  PsTerminateSystemThread(STATUS_SUCCESS);
}

NTSTATUS
DokanStartTimeoutScanThread(__in PDOKAN_GLOBAL DokanGlobal)
/*++

Routine Description:

        starts the global IRP timeout scanner thread

--*/
{
  NTSTATUS status;
  HANDLE thread;

  status =
      PsCreateSystemThread(&thread, THREAD_ALL_ACCESS, NULL, NULL, NULL,
                           (PKSTART_ROUTINE)DokanTimeoutScanThread, DokanGlobal);

  if (!NT_SUCCESS(status)) {
    DOKAN_LOG("Failed to create Thread");
    return status;
  }

  ObReferenceObjectByHandle(thread, THREAD_ALL_ACCESS, NULL, KernelMode,
                            (PVOID *)&DokanGlobal->TimeoutScanThread, NULL);

  ZwClose(thread);

  return STATUS_SUCCESS;
}

VOID DokanStopTimeoutScanThread(__in PDOKAN_GLOBAL DokanGlobal)
/*++

Routine Description:

        stops the global IRP timeout scanner thread

--*/
{
  KeSetEvent(&DokanGlobal->TimeoutScanKillEvent, IO_NO_INCREMENT, FALSE);
  if (DokanGlobal->TimeoutScanThread == NULL) {
    return;
  }

  ASSERT(KeGetCurrentIrql() <= APC_LEVEL);
  KeWaitForSingleObject(DokanGlobal->TimeoutScanThread, Executive, KernelMode,
                        FALSE, NULL);
  ObDereferenceObject(DokanGlobal->TimeoutScanThread);
  DokanGlobal->TimeoutScanThread = NULL;
}

VOID DokanUpdateTimeout(__out PLARGE_INTEGER TickCount, __in ULONG Timeout) {
  KeQueryTickCount(TickCount);
  TickCount->QuadPart += Timeout * 1000 * 10 / KeQueryTimeIncrement();
}
