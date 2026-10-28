/* Rune's isolated memory-image decoder. Rune source uses the repository's zlib
 * license; stb_image.h retains its MIT/public-domain notice and exact source pin.
 * No raylib state, callbacks, paths, logging, or external stbi_* symbols.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <limits.h>

#define STB_IMAGE_STATIC
#define STBI_NO_STDIO
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#ifndef STBI_THREAD_LOCAL
#error "Rune's isolated decoder requires thread-local stb failure state"
#endif

typedef struct Rune_Image {
    void *pixels;
    int32_t width, height, channels;
    uint32_t floating_point;
    uint64_t size_bytes;
} Rune_Image;

static void copy_error(char *buffer, size_t capacity, const char *message)
{
    if (!buffer || !capacity) return;
    if (!message) message = "could not decode image";
    size_t length = strlen(message);
    if (length >= capacity) length = capacity - 1;
    memcpy(buffer, message, length);
    buffer[length] = 0;
}

int Rune_Image_Decode(const unsigned char *bytes, size_t size,
                      uint64_t maximum_output_bytes, Rune_Image *out,
                      char *error, size_t error_capacity)
{
    if (out) memset(out, 0, sizeof(*out));
    if (error && error_capacity) error[0] = 0;
    if (!out || !bytes || !size || size > INT_MAX || !maximum_output_bytes) {
        copy_error(error, error_capacity, "invalid image input or output limit");
        return 0;
    }

    // This private symbol is TLS, enforced above. No stale request error leaks
    // into a later failure, and no other translation unit can change settings.
    stbi__g_failure_reason = NULL;
    int width = 0, height = 0, channels = 0;
    if (!stbi_info_from_memory(bytes, (int)size, &width, &height, &channels)) {
        copy_error(error, error_capacity, stbi_failure_reason());
        return 0;
    }
    int floating_point = stbi_is_hdr_from_memory(bytes, (int)size);
    if (width <= 0 || height <= 0 || channels < 1 || channels > 4) {
        copy_error(error, error_capacity, "invalid image dimensions or channels");
        return 0;
    }
    uint64_t pixel_bytes = (uint64_t)channels * (floating_point ? 4u : 1u);
    uint64_t count = (uint64_t)width * (uint64_t)height;
    if (count > maximum_output_bytes / pixel_bytes) {
        copy_error(error, error_capacity, "decoded image exceeds output limit");
        return 0;
    }

    void *pixels = floating_point
        ? (void *)stbi_loadf_from_memory(bytes, (int)size, &width, &height, &channels, 0)
        : (void *)stbi_load_from_memory(bytes, (int)size, &width, &height, &channels, 0);
    if (!pixels) {
        copy_error(error, error_capacity, stbi_failure_reason());
        return 0;
    }
    uint64_t decoded_bytes = (uint64_t)width * (uint64_t)height * (uint64_t)channels * (floating_point ? 4u : 1u);
    if (width <= 0 || height <= 0 || channels < 1 || channels > 4 || decoded_bytes > maximum_output_bytes) {
        stbi_image_free(pixels);
        copy_error(error, error_capacity, "decoded image exceeds output limit");
        return 0;
    }
    *out = (Rune_Image){pixels, width, height, channels, (uint32_t)floating_point, decoded_bytes};
    return 1;
}

void Rune_Image_Free(void *pixels)
{
    stbi_image_free(pixels);
}
