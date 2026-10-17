#pragma once
#include <stdint.h>
#include <sys/types.h>
// Returns the PTY master or -1 with errno; reports exec failures synchronously.
int dp_terminal_spawn(const char *shell, const char *cwd, char *const env[], uint16_t rows, uint16_t columns, pid_t *pid);
