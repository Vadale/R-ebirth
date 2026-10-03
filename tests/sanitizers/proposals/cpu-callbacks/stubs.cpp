#include "shared.h"

void ggml_vec_dot_f32(int n, float * s, size_t bs, const float * x, size_t bx, const float * y, size_t by, int nrc) {
    assert(expected.id == 0 && n == 3 && nrc == 1 && bs == 8 && bx == 12 && by == 16);
    assert(x == expected.x && y == expected.y && s == expected.s);
    expected.calls++; *s = 25.0f + 0;
}

void ggml_vec_dot_f16(int n, float * s, size_t bs, ggml_fp16_t * x, size_t bx, ggml_fp16_t * y, size_t by, int nrc) {
    assert(expected.id == 1 && n == 3 && nrc == 1 && bs == 8 && bx == 12 && by == 16);
    assert(x == expected.x && y == expected.y && s == expected.s);
    expected.calls++; *s = 25.0f + 1;
}

void ggml_vec_dot_bf16(int n, float * s, size_t bs, ggml_bf16_t * x, size_t bx, ggml_bf16_t * y, size_t by, int nrc) {
    assert(expected.id == 2 && n == 3 && nrc == 1 && bs == 8 && bx == 12 && by == 16);
    assert(x == expected.x && y == expected.y && s == expected.s);
    expected.calls++; *s = 25.0f + 2;
}

void ggml_cpu_fp32_to_fp32(const float * x, float * y, int64_t n) {
    assert(expected.id == 3 && x == expected.x && y == expected.y && n == 3);
    expected.calls++; memset(y, 3, sizeof(*y) * 3);
}

void ggml_cpu_fp32_to_fp16(const float * x, ggml_fp16_t * y, int64_t n) {
    assert(expected.id == 4 && x == expected.x && y == expected.y && n == 3);
    expected.calls++; memset(y, 4, sizeof(*y) * 3);
}

void ggml_cpu_fp32_to_bf16(const float * x, ggml_bf16_t * y, int64_t n) {
    assert(expected.id == 5 && x == expected.x && y == expected.y && n == 3);
    expected.calls++; memset(y, 5, sizeof(*y) * 3);
}

void ggml_cpu_fp32_to_i32(const float * x, int32_t * y, int64_t n) {
    assert(expected.id == 6 && x == expected.x && y == expected.y && n == 3);
    expected.calls++; memset(y, 6, sizeof(*y) * 3);
}
