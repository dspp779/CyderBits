/* Cost of small ReadFile calls under Wine, the way the WZ parser reads.
 * usage: readbench.exe FILE N SIZE
 * Prints microseconds per call for:
 *   ptr  - ReadFile using the file pointer (SetFilePointer once, then sequential)
 *   off  - ReadFile with an explicit OVERLAPPED offset (no file pointer use)
 *   hot  - the same 4 KiB window re-read with explicit offsets (always cached)
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static double now_us(void)
{
    static LARGE_INTEGER f;
    LARGE_INTEGER c;
    if (!f.QuadPart) QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1e6 / (double)f.QuadPart;
}

int main(int argc, char **argv)
{
    HANDLE h;
    DWORD n, size, got, i;
    char buf[65536];
    double t;
    LARGE_INTEGER fsz;

    if (argc != 4) { fprintf(stderr, "usage: readbench FILE N SIZE\n"); return 2; }
    n = (DWORD)atoi(argv[2]);
    size = (DWORD)atoi(argv[3]);
    if (size > sizeof(buf)) size = sizeof(buf);

    h = CreateFileA(argv[1], GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) { fprintf(stderr, "open failed %lu\n", GetLastError()); return 1; }
    GetFileSizeEx(h, &fsz);

    /* warm the cache window once */
    ReadFile(h, buf, size, &got, NULL);

    SetFilePointer(h, 0, NULL, FILE_BEGIN);
    t = now_us();
    for (i = 0; i < n; i++)
    {
        if (!ReadFile(h, buf, size, &got, NULL) || !got) SetFilePointer(h, 0, NULL, FILE_BEGIN);
    }
    printf("ptr  size=%lu n=%lu  %.2f us/call\n", size, n, (now_us() - t) / n);

    t = now_us();
    for (i = 0; i < n; i++)
    {
        OVERLAPPED ov = {0};
        ULONGLONG off = ((ULONGLONG)i * size) % (ULONGLONG)(fsz.QuadPart > size ? fsz.QuadPart - size : 1);
        ov.Offset = (DWORD)off;
        ov.OffsetHigh = (DWORD)(off >> 32);
        ReadFile(h, buf, size, &got, &ov);
    }
    printf("off  size=%lu n=%lu  %.2f us/call\n", size, n, (now_us() - t) / n);

    t = now_us();
    for (i = 0; i < n; i++)
    {
        OVERLAPPED ov = {0};
        ov.Offset = (DWORD)((i * size) % 4096);
        ReadFile(h, buf, size, &got, &ov);
    }
    printf("hot  size=%lu n=%lu  %.2f us/call\n", size, n, (now_us() - t) / n);

    /* baseline: a trivial Wine syscall, to separate dispatcher cost */
    t = now_us();
    for (i = 0; i < n; i++)
    {
        LARGE_INTEGER pos, zero = {0};
        SetFilePointerEx(h, zero, &pos, FILE_CURRENT);
    }
    printf("seek size=0 n=%lu  %.2f us/call (SetFilePointerEx query)\n", n, (now_us() - t) / n);

    CloseHandle(h);
    return 0;
}
