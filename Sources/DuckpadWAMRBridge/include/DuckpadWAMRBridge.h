#ifndef DUCKPAD_WAMR_BRIDGE_H
#define DUCKPAD_WAMR_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint32_t module_bytes;
    uint32_t stack_bytes;
    uint32_t heap_bytes;
    uint32_t output_bytes;
} DPWAMRLimits;

/// Runs one capability-free Duckpad ABI command. The runtime registers no
/// native imports and unloads the module after each invocation.
bool dp_wamr_invoke(
    const uint8_t *module_bytes,
    size_t module_length,
    uint32_t command,
    const uint8_t *input,
    uint32_t input_length,
    DPWAMRLimits limits,
    uint8_t *output,
    uint32_t *output_length,
    char *error,
    uint32_t error_capacity
);

/// Asynchronously traps the one in-process interpreter invocation. Safe to
/// call from the XPC invalidation/watchdog thread.
void dp_wamr_prepare_current(void);
void dp_wamr_cancel_current(void);

#endif
