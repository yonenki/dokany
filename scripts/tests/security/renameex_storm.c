// Stress regression test for textil#2195: rename completions through
// FileRenameInformationEx must hold the VCB lock while renaming the FCB in
// the name AVL table. On a buggy driver this storm corrupts the table and
// crashes in DokanCompareFcb within seconds; on a fixed driver it completes.
#include <stdio.h>
#include <windows.h>

typedef struct _IO_STATUS_BLOCK {
  union { NTSTATUS Status; PVOID Pointer; } u;
  ULONG_PTR Information;
} IO_STATUS_BLOCK, *PIO_STATUS_BLOCK;

typedef NTSTATUS(NTAPI *PNtSetInformationFile)(HANDLE, PIO_STATUS_BLOCK, PVOID,
                                               ULONG, ULONG);

typedef struct {
  ULONG Flags;
  HANDLE RootDirectory;
  ULONG FileNameLength;
  WCHAR FileName[1];
} MY_RENAME_INFO_EX;

#define MY_FileRenameInformationEx 65
#define FILE_RENAME_REPLACE_IF_EXISTS 0x1

static PNtSetInformationFile g_NtSetInformationFile;
static WCHAR g_dir[MAX_PATH];
static volatile LONG g_stop = 0;
static volatile LONG g_renames = 0;

static BOOL RenameEx(LPCWSTR from, LPCWSTR to) {
  HANDLE h = CreateFileW(from, DELETE,
                         FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (h == INVALID_HANDLE_VALUE)
    return FALSE;
  char buf[512];
  ZeroMemory(buf, sizeof buf);
  MY_RENAME_INFO_EX *ri = (MY_RENAME_INFO_EX *)buf;
  ri->Flags = FILE_RENAME_REPLACE_IF_EXISTS;
  size_t len = (wcslen(to) + 1) * sizeof(WCHAR);
  ri->FileNameLength = (ULONG)len;
  memcpy(ri->FileName, to, len);
  IO_STATUS_BLOCK iosb;
  NTSTATUS st =
      g_NtSetInformationFile(h, &iosb, buf, sizeof buf, MY_FileRenameInformationEx);
  CloseHandle(h);
  return st == 0;
}

static DWORD WINAPI Renamer(LPVOID p) {
  int id = (int)(ULONG_PTR)p;
  WCHAR a[MAX_PATH], b[MAX_PATH];
  WCHAR na[64], nb[64];
  swprintf(a, MAX_PATH, L"%s\\f%da.txt", g_dir, id);
  swprintf(b, MAX_PATH, L"%s\\f%db.txt", g_dir, id);
  swprintf(na, 64, L"f%da.txt", id);
  swprintf(nb, 64, L"f%db.txt", id);
  HANDLE h = CreateFileW(a, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL, NULL);
  if (h != INVALID_HANDLE_VALUE)
    CloseHandle(h);
  while (!g_stop) {
    if (RenameEx(a, nb)) {
      InterlockedIncrement(&g_renames);
      if (RenameEx(b, na))
        InterlockedIncrement(&g_renames);
    } else {
      HANDLE r = CreateFileW(a, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                             FILE_ATTRIBUTE_NORMAL, NULL);
      if (r != INVALID_HANDLE_VALUE)
        CloseHandle(r);
    }
  }
  return 0;
}

static DWORD WINAPI Opener(LPVOID p) {
  int id = (int)(ULONG_PTR)p;
  WCHAR path[MAX_PATH];
  while (!g_stop) {
    for (int i = 0; i < 8; i++) {
      swprintf(path, MAX_PATH, L"%s\\f%d%c.txt", g_dir, i,
               (i + id) % 2 ? L'a' : L'b');
      HANDLE h = CreateFileW(path, GENERIC_READ,
                             FILE_SHARE_READ | FILE_SHARE_WRITE |
                                 FILE_SHARE_DELETE,
                             NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
      if (h != INVALID_HANDLE_VALUE)
        CloseHandle(h);
    }
  }
  return 0;
}

// usage: renameex_storm <dir> [seconds]
int wmain(int argc, wchar_t **argv) {
  if (argc < 2) {
    printf("usage: renameex_storm <dir> [seconds]\n");
    return 2;
  }
  wcscpy_s(g_dir, MAX_PATH, argv[1]);
  int seconds = argc > 2 ? _wtoi(argv[2]) : 60;
  g_NtSetInformationFile =
      (PNtSetInformationFile)GetProcAddress(GetModuleHandleW(L"ntdll.dll"),
                                            "NtSetInformationFile");
  HANDLE th[16];
  for (int i = 0; i < 8; i++)
    th[i] = CreateThread(NULL, 0, Renamer, (LPVOID)(ULONG_PTR)i, 0, NULL);
  for (int i = 0; i < 8; i++)
    th[8 + i] = CreateThread(NULL, 0, Opener, (LPVOID)(ULONG_PTR)i, 0, NULL);
  Sleep(seconds * 1000);
  InterlockedExchange(&g_stop, 1);
  WaitForMultipleObjects(16, th, TRUE, 30000);
  printf("done renames=%ld\n", g_renames);
  return g_renames > 0 ? 0 : 1;
}
