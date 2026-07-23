// Regression test for textil#2198: dokan_np NPGetConnection must not write
// past the buffer size it asked the caller for. The harness allocates a
// marker-filled tail and passes exactly the declared size; any out-of-bounds
// write lands in the marked tail. Needs a network (UNC) mount to be present
// and the dokannp DLL path passed as argument.
#include <stdio.h>
#include <windows.h>

typedef DWORD(APIENTRY *PNPGetConnection)(LPWSTR, LPWSTR, LPDWORD);

// usage: np_oob_write <dokannp dll path> [drive letter]
int wmain(int argc, wchar_t **argv) {
  if (argc < 2) {
    printf("usage: np_oob_write <dokannp dll> [drive]\n");
    return 2;
  }
  LPCWSTR dll = argv[1];
  WCHAR drive[3] = L"R:";
  if (argc > 2)
    wcscpy_s(drive, 3, argv[2]);
  HMODULE h = LoadLibraryW(dll);
  if (!h) {
    printf("SKIP: load %ws failed %lu\n", dll, GetLastError());
    return 3;
  }
  PNPGetConnection NPGetConnection =
      (PNPGetConnection)GetProcAddress(h, "NPGetConnection");
  DWORD size = 0;
  DWORD rc = NPGetConnection(drive, NULL, &size);
  if (rc != 0xEA /*WN_MORE_DATA*/ || size == 0) {
    printf("SKIP: probe rc=%lu size=%lu (no UNC mount?)\n", rc, size);
    return 3;
  }
  DWORD tail = 64;
  BYTE *buf = (BYTE *)malloc(size + tail);
  memset(buf, 0xAA, size + tail);
  DWORD size2 = size;
  rc = NPGetConnection(drive, (LPWSTR)buf, &size2);
  int oob = 0;
  for (DWORD i = size; i < size + 8; i++) {
    if (buf[i] != 0xAA) {
      printf("OOB WRITE at offset %lu (past declared %lu): 0x%02x\n", i, size,
             buf[i]);
      oob = 1;
    }
  }
  printf(oob ? "RESULT: OOB write confirmed\n" : "RESULT: no OOB write\n");
  return oob ? 1 : 0;
}
