#include "DuckpadTerminalBridge.h"
#include <util.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/wait.h>

int dp_terminal_spawn(const char *shell, const char *cwd, char *const env[], uint16_t rows, uint16_t columns, pid_t *pid) {
    int master, slave, status[2];
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    if (openpty(&master, &slave, NULL, NULL, &size) < 0) return -1;
    if (pipe(status) < 0) { int e = errno; close(master); close(slave); errno = e; return -1; }
    fcntl(master, F_SETFD, FD_CLOEXEC);
    fcntl(slave, F_SETFD, FD_CLOEXEC);
    fcntl(status[0], F_SETFD, FD_CLOEXEC);
    fcntl(status[1], F_SETFD, FD_CLOEXEC);
    const int maximumFD = getdtablesize();
    pid_t child = fork();
    if (child == 0) {
        // Only async-signal-safe C/POSIX operations after fork in the XPC process.
        close(master); close(status[0]);
        sigset_t empty; sigemptyset(&empty); sigprocmask(SIG_SETMASK, &empty, NULL);
        for (int s = 1; s < NSIG; s++) signal(s, SIG_DFL);
        if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0 || chdir(cwd) < 0) goto failed;
        for (int i = 0; i < 3; i++) if (dup2(slave, i) < 0) goto failed;
        for (int i = 3; i < maximumFD; i++) if (i != status[1]) close(i);
        char *const argv[] = { (char *)shell, "-l", NULL };
        execve(shell, argv, env);
failed: ;
        int e = errno;
        ssize_t sent;
        do { sent = write(status[1], &e, sizeof(e)); } while (sent < 0 && errno == EINTR);
        _exit(127);
    }
    int saved = errno;
    close(slave); close(status[1]);
    if (child < 0) { close(master); close(status[0]); errno = saved; return -1; }
    int error = 0; ssize_t count;
    do { count = read(status[0], &error, sizeof(error)); } while (count < 0 && errno == EINTR);
    close(status[0]);
    if (count != 0) {
        close(master); kill(child, SIGKILL);
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
        errno = error ? error : EIO; return -1;
    }
    *pid = child;
    return master;
}
