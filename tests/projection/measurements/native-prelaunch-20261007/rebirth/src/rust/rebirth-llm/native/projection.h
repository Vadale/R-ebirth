#pragma once
#include <stddef.h>
#include <stdint.h>
struct ggml_tensor;
extern "C" {
// No tensor pointers are returned or retained. Codes: 0 supported, 1 residual
// duplicate (not a producer), negative = unsupported/inconsistent.
struct relm_projection_info { uint64_t rows; uint64_t bytes; uint32_t wrappers; uint32_t host; };
int relm_projection_classify(const ggml_tensor *, uint32_t layer, uint32_t component,
                            size_t width, bool ready, relm_projection_info *);
int relm_projection_row(ggml_tensor *, size_t width, size_t row, float *, bool write);
int relm_projection_consumer(const ggml_tensor *, uint32_t layer, uint32_t component, size_t width);
uint64_t relm_projection_classifier_controls();
size_t relm_projection_info_size();
size_t relm_projection_name_frame_size();
}
