/* Replay a forward strided read pattern on a (cold) file, with or without
 * F_RDADVISE read-ahead, and report the time per 8 KiB read.
 * usage: replay FILE STEPS.txt MODE [AHEAD_KB]
 *   STEPS.txt: one step size in bytes per line (gaps between reads)
 *   MODE: plain | advise
 * advise: when a read gets within AHEAD/2 of the advised frontier, ask the
 * kernel (asynchronously) to read the next AHEAD bytes past the frontier. */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
    if (argc < 4) { fprintf(stderr, "usage\n"); return 2; }
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    struct stat st; fstat(fd, &st);
    FILE *f = fopen(argv[2], "r");
    long steps[20000]; int n = 0;
    while (n < 20000 && fscanf(f, "%ld", &steps[n]) == 1) n++;
    fclose(f);
    int advise = !strcmp(argv[3], "advise");
    long ahead = (argc > 4 ? atol(argv[4]) : 2048) * 1024;
    int depth = argc > 5 ? atoi(argv[5]) : 1;
    char buf[8192];
    off_t pos = 8192, frontier = 0;
    double worst = 0, t0 = now();
    int reads = 0;
    for (int i = 0; i <= n && pos + 8192 <= st.st_size; i++)
    {
        while (advise && frontier < pos + (off_t)depth * ahead)
        {
            off_t start = frontier > pos ? frontier : pos;
            struct radvisory ra = { .ra_offset = start, .ra_count = (int)ahead };
            fcntl(fd, F_RDADVISE, &ra);
            frontier = start + ahead;
        }
        double t = now();
        if (pread(fd, buf, sizeof(buf), pos) <= 0) break;
        t = now() - t;
        if (t > worst) worst = t;
        reads++;
        if (i < n) pos += steps[i];
    }
    double total = now() - t0;
    printf("%s ahead=%ldKB depth=%d: %d reads, %.1f ms total, %.1f us/read, worst %.0f us\n",
           argv[3], ahead / 1024, depth, reads, total * 1e3, total / reads * 1e6, worst * 1e6);
    return 0;
}
