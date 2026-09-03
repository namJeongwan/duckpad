#include "DuckpadWAMRBridge.h"
#include "WAMRRuntime.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

static pthread_mutex_t invocation_mutex = PTHREAD_MUTEX_INITIALIZER;
static wasm_module_inst_t current_instance = NULL;
static wasm_exec_env_t current_environment = NULL;
static bool cancellation_requested = false;

void dp_wamr_prepare_current(void) {
    pthread_mutex_lock(&invocation_mutex);
    current_instance = NULL;
    current_environment = NULL;
    cancellation_requested = false;
    pthread_mutex_unlock(&invocation_mutex);
}

void dp_wamr_cancel_current(void) {
    pthread_mutex_lock(&invocation_mutex);
    cancellation_requested = true;
    if (current_environment)
        wasm_runtime_set_instruction_count_limit(current_environment, 0);
    if (current_instance) wasm_runtime_terminate(current_instance);
    pthread_mutex_unlock(&invocation_mutex);
}

static void copy_error(char *destination, uint32_t capacity, const char *message) {
    if (!destination || capacity == 0) return;
    if (!message) message = "unknown WAMR failure";
    size_t count = strlen(message);
    if (count >= capacity) count = capacity - 1;
    memcpy(destination, message, count);
    destination[count] = '\0';
}

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
) {
    if (!module_bytes || module_length == 0 || module_length > UINT32_MAX ||
        module_length > limits.module_bytes || !output_length ||
        (input_length > 0 && !input) ||
        limits.stack_bytes < 4096 || limits.heap_bytes < 4096) {
        copy_error(error, error_capacity, "invalid invocation limits");
        return false;
    }
    RuntimeInitArgs init_args;
    memset(&init_args, 0, sizeof(init_args));
    init_args.mem_alloc_type = Alloc_With_System_Allocator;
    init_args.mem_alloc_option.allocator.malloc_func = malloc;
    init_args.mem_alloc_option.allocator.realloc_func = realloc;
    init_args.mem_alloc_option.allocator.free_func = free;
    if (!wasm_runtime_full_init(&init_args)) {
        copy_error(error, error_capacity, "WAMR initialization failed");
        return false;
    }

    bool succeeded = false;
    wasm_module_t module = NULL;
    wasm_module_inst_t instance = NULL;
    wasm_exec_env_t environment = NULL;
    char runtime_error[256] = {0};
    uint32_t input_offset = 0;
    void *native_input = NULL;

    module = wasm_runtime_load((uint8_t *)module_bytes, (uint32_t)module_length,
                               runtime_error, sizeof(runtime_error));
    if (!module) goto done;
    instance = wasm_runtime_instantiate(module, limits.stack_bytes,
                                        limits.heap_bytes, runtime_error,
                                        sizeof(runtime_error));
    if (!instance) goto done;
    pthread_mutex_lock(&invocation_mutex);
    current_instance = instance;
    bool cancel_before_instance = cancellation_requested;
    pthread_mutex_unlock(&invocation_mutex);
    if (cancel_before_instance) wasm_runtime_terminate(instance);
    environment = wasm_runtime_create_exec_env(instance, limits.stack_bytes);
    if (!environment) {
        copy_error(runtime_error, sizeof(runtime_error), "execution environment allocation failed");
        goto done;
    }
    wasm_runtime_set_instruction_count_limit(environment, -1);
    pthread_mutex_lock(&invocation_mutex);
    current_environment = environment;
    cancel_before_instance = cancellation_requested;
    pthread_mutex_unlock(&invocation_mutex);
    if (cancel_before_instance)
        wasm_runtime_set_instruction_count_limit(environment, 0);
    if (input_length > 0) {
        input_offset = wasm_runtime_module_malloc(instance, input_length, &native_input);
        if (!input_offset || !native_input) {
            copy_error(runtime_error, sizeof(runtime_error), "module input allocation failed");
            goto done;
        }
        memcpy(native_input, input, input_length);
    }

    wasm_function_inst_t invoke = wasm_runtime_lookup_function(instance, "duckpad_invoke");
    wasm_function_inst_t output_pointer = wasm_runtime_lookup_function(instance, "duckpad_output_pointer");
    wasm_function_inst_t output_size = wasm_runtime_lookup_function(instance, "duckpad_output_length");
    if (!invoke || !output_pointer || !output_size) {
        copy_error(runtime_error, sizeof(runtime_error), "missing duckpad-wasm-1 exports");
        goto done;
    }
    uint32_t invoke_argv[3] = {command, input_offset, input_length};
    if (!wasm_runtime_call_wasm(environment, invoke, 3, invoke_argv) || invoke_argv[0] != 0) goto done;
    uint32_t pointer_argv[1] = {0};
    uint32_t length_argv[1] = {0};
    if (!wasm_runtime_call_wasm(environment, output_pointer, 0, pointer_argv) ||
        !wasm_runtime_call_wasm(environment, output_size, 0, length_argv)) goto done;
    uint32_t produced = length_argv[0];
    if (produced > limits.output_bytes || produced > *output_length ||
        (produced > 0 && output == NULL) ||
        !wasm_runtime_validate_app_addr(instance, pointer_argv[0], produced)) {
        copy_error(runtime_error, sizeof(runtime_error), "plugin output exceeds validated bounds");
        goto done;
    }
    if (produced > 0) {
        void *native_output = wasm_runtime_addr_app_to_native(instance, pointer_argv[0]);
        if (!native_output) {
            copy_error(runtime_error, sizeof(runtime_error), "plugin output pointer is invalid");
            goto done;
        }
        memcpy(output, native_output, produced);
    }
    *output_length = produced;
    succeeded = true;

done:
    pthread_mutex_lock(&invocation_mutex);
    current_instance = NULL;
    current_environment = NULL;
    cancellation_requested = false;
    pthread_mutex_unlock(&invocation_mutex);
    if (!succeeded) {
        const char *exception = instance ? wasm_runtime_get_exception(instance) : NULL;
        copy_error(error, error_capacity, exception ? exception : runtime_error);
    }
    if (input_offset && instance) wasm_runtime_module_free(instance, input_offset);
    if (environment) wasm_runtime_destroy_exec_env(environment);
    if (instance) wasm_runtime_deinstantiate(instance);
    if (module) wasm_runtime_unload(module);
    wasm_runtime_destroy();
    return succeeded;
}
