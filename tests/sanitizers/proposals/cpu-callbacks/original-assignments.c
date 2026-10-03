#include "shared.h"
ggml_vec_dot_t callback_0 = (ggml_vec_dot_t) ggml_vec_dot_f32;
ggml_vec_dot_t callback_1 = (ggml_vec_dot_t) ggml_vec_dot_f16;
ggml_vec_dot_t callback_2 = (ggml_vec_dot_t) ggml_vec_dot_bf16;
ggml_from_float_t callback_3 = (ggml_from_float_t) ggml_cpu_fp32_to_fp32;
ggml_from_float_t callback_4 = (ggml_from_float_t) ggml_cpu_fp32_to_fp16;
ggml_from_float_t callback_5 = (ggml_from_float_t) ggml_cpu_fp32_to_bf16;
ggml_from_float_t callback_6 = (ggml_from_float_t) ggml_cpu_fp32_to_i32;
