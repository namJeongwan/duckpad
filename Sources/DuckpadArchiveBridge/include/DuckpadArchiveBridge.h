#include <stdint.h>
#include <stddef.h>
int duckpad_inflate(const uint8_t *input, size_t input_size, uint8_t *output, size_t output_size);
uint32_t duckpad_crc32(const uint8_t *bytes, size_t size);
