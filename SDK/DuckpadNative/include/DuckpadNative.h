#ifndef DUCKPAD_NATIVE_H
#define DUCKPAD_NATIVE_H
#include <stdint.h>
#include <stddef.h>
// All entry points and callbacks run on the AppKit main thread.
// UTF-8 inputs are borrowed only for the duration of the call.
// Native code runs with the host process's authority; capabilities are consent,
// not a sandbox boundary. No C++/Swift exceptions may cross this C ABI.
#define DUCKPAD_NATIVE_ABI_VERSION 1

typedef struct DuckpadHostV1 {
    uint32_t abi_version;
    uint32_t struct_size;
    void *context;
    uint64_t (*prepare_insert)(void *context);
    int32_t (*insert_text)(void *context, uint64_t token, const uint8_t *utf8, size_t length);
    void (*close_panel)(void *context);
} DuckpadHostV1;

// Required exports. create copies the host table and config JSON before returning.
// Config: language, resourceDirectory, storageDirectory, commandID (UTF-8 JSON).
uint32_t duckpad_native_abi_version(void);
void *duckpad_native_create(const DuckpadHostV1 *host, const uint8_t *config, size_t length);
// Returns a borrowed NSView*. The plugin owns it until destroy, host retains it
// while docked. The host detaches it before deactivate/destroy.
void *duckpad_native_view(void *instance);
void duckpad_native_set_language(void *instance, const char *language);
// Stop timers/tasks and detach external callbacks; must be idempotent.
void duckpad_native_deactivate(void *instance);
void duckpad_native_destroy(void *instance);
#endif
