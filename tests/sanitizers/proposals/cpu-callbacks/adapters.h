// Exact-signature entry points for the generic CPU trait callbacks.

static void ggml_vec_dot_f32_adapter(int n, float * s, size_t bs, const void * x, size_t bx, const void * y, size_t by, int nrc) {
    ggml_vec_dot_f32(n, s, bs, (const float *) x, bx, (const float *) y, by, nrc);
}

static void ggml_vec_dot_f16_adapter(int n, float * s, size_t bs, const void * x, size_t bx, const void * y, size_t by, int nrc) {
    ggml_vec_dot_f16(n, s, bs, (ggml_fp16_t *) x, bx, (ggml_fp16_t *) y, by, nrc);
}

static void ggml_vec_dot_bf16_adapter(int n, float * s, size_t bs, const void * x, size_t bx, const void * y, size_t by, int nrc) {
    ggml_vec_dot_bf16(n, s, bs, (ggml_bf16_t *) x, bx, (ggml_bf16_t *) y, by, nrc);
}

static void ggml_cpu_fp32_to_fp32_adapter(const float * x, void * y, int64_t n) {
    ggml_cpu_fp32_to_fp32(x, (float *) y, n);
}

static void ggml_cpu_fp32_to_fp16_adapter(const float * x, void * y, int64_t n) {
    ggml_cpu_fp32_to_fp16(x, (ggml_fp16_t *) y, n);
}

static void ggml_cpu_fp32_to_bf16_adapter(const float * x, void * y, int64_t n) {
    ggml_cpu_fp32_to_bf16(x, (ggml_bf16_t *) y, n);
}

static void ggml_cpu_fp32_to_i32_adapter(const float * x, void * y, int64_t n) {
    ggml_cpu_fp32_to_i32(x, (int32_t *) y, n);
}

