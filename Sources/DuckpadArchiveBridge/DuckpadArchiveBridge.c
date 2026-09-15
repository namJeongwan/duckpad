#include "DuckpadArchiveBridge.h"
#include <zlib.h>
#include <limits.h>
int duckpad_inflate(const uint8_t *input, size_t input_size, uint8_t *output, size_t output_size) {
    if (input_size > UINT_MAX || output_size > UINT_MAX) return 0;
    z_stream stream = {0};
    stream.next_in = (Bytef *)input; stream.avail_in = (uInt)input_size;
    stream.next_out = output; stream.avail_out = (uInt)(output_size ? output_size : 1);
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return 0;
    int status = inflate(&stream, Z_FINISH);
    int valid = status == Z_STREAM_END && stream.total_in == input_size && stream.total_out == output_size;
    inflateEnd(&stream);
    return valid;
}
uint32_t duckpad_crc32(const uint8_t *bytes, size_t size) {
    return (uint32_t)crc32(0, bytes, (uInt)size);
}
