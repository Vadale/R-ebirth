#include "shared.h"
#include "adapters.h"
ggml_vec_dot_t callback_0 = ggml_vec_dot_f32_adapter;
ggml_vec_dot_t callback_1 = ggml_vec_dot_f16_adapter;
ggml_vec_dot_t callback_2 = ggml_vec_dot_bf16_adapter;
ggml_from_float_t callback_3 = ggml_cpu_fp32_to_fp32_adapter;
ggml_from_float_t callback_4 = ggml_cpu_fp32_to_fp16_adapter;
ggml_from_float_t callback_5 = ggml_cpu_fp32_to_bf16_adapter;
ggml_from_float_t callback_6 = ggml_cpu_fp32_to_i32_adapter;
