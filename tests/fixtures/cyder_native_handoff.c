#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <limits.h>
#include <fcntl.h>
#include <errno.h>

int main(void) {
    /* Session critical-section locks must never survive into a game. */
    if (fcntl(9, F_GETFD) != -1 || errno != EBADF) return 94;
    const char *root = getenv("TEST_ROOT");
    if (!root) return 90;
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/native.entered", root);
    FILE *file = fopen(path, "w");
    if (!file) return 91;
#ifdef __x86_64__
    fprintf(file, "%d x86_64\n", getpid());
#else
    fprintf(file, "%d wrong-architecture\n", getpid());
#endif
    fclose(file);
    snprintf(path, sizeof(path), "%s/native.release", root);
    while (access(path, F_OK) != 0) usleep(20000);
    return 53;
}
