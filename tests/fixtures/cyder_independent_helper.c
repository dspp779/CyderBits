#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <signal.h>
#include <fcntl.h>

// Our own headless native fixture, deliberately orphaned before discovery.
int main(void) {
    pid_t child = fork();
    if (child < 0) return 1;
    if (child > 0) { printf("%d\n", child); fflush(stdout); return 0; }
    setsid();
    int nullfd = open("/dev/null", O_RDWR);
    if (nullfd >= 0) { dup2(nullfd, 0); dup2(nullfd, 1); dup2(nullfd, 2); if (nullfd > 2) close(nullfd); }
    alarm(120);
    for (;;) pause();
}
