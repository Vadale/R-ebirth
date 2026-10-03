#include "shared.h"
#include "adapters.h"
#include <stdlib.h>
#include <stdio.h>
struct expected_call expected;
int main(int argc, char **argv) {
    void * x = calloc(32, 1); void * y = calloc(32, 1); float s = 0;
    assert(x && y);
    ggml_vec_dot_t volatile dot[] = {ggml_vec_dot_f32_adapter, ggml_vec_dot_f16_adapter, ggml_vec_dot_bf16_adapter};
    ggml_from_float_t volatile convert[] = {ggml_cpu_fp32_to_fp32_adapter, ggml_cpu_fp32_to_fp16_adapter, ggml_cpu_fp32_to_bf16_adapter, ggml_cpu_fp32_to_i32_adapter};
    expected.x=x; expected.y=y; expected.s=&s;
    if (argc == 2) {
        assert(strlen(argv[1]) == 1 && argv[1][0] >= '0' && argv[1][0] <= '6');
        const int id = argv[1][0] - '0';
        ggml_vec_dot_t volatile original_dot[] = {
            (ggml_vec_dot_t)ggml_vec_dot_f32,
            (ggml_vec_dot_t)ggml_vec_dot_f16,
            (ggml_vec_dot_t)ggml_vec_dot_bf16
        };
        ggml_from_float_t volatile original_convert[] = {
            (ggml_from_float_t)ggml_cpu_fp32_to_fp32,
            (ggml_from_float_t)ggml_cpu_fp32_to_fp16,
            (ggml_from_float_t)ggml_cpu_fp32_to_bf16,
            (ggml_from_float_t)ggml_cpu_fp32_to_i32
        };
        expected.id = id;
        if (id < 3) original_dot[id](3, &s, 8, x, 12, y, 16, 1);
        else original_convert[id - 3]((const float *)x, y, 3);
        assert(expected.calls == 1);
        free(x); free(y);
        printf("ORIGINAL_TYPE_MISMATCH_SURVIVED %d\n", id);
        return 0;
    }
    assert(argc == 1);
    for (int i=0; i<3; i++) {
        expected.id=i; expected.calls=0;
        dot[i](3,&s,8,x,12,y,16,1);
        assert(expected.calls==1 && s==25.0f+i);
        printf("CALLBACK_PASS %d\n",i);
    }
    const size_t widths[] = {sizeof(float),sizeof(ggml_fp16_t),sizeof(ggml_bf16_t),sizeof(int32_t)};
    for (int i=0; i<4; i++) {
        memset(y,0,32); expected.id=i+3; expected.calls=0;
        convert[i]((const float*)x,y,3);
        assert(expected.calls==1);
        for (size_t k=0;k<widths[i]*3;k++) assert(((unsigned char*)y)[k] == i+3);
        printf("CALLBACK_PASS %d\n",i+3);
    }
    free(x);free(y);puts("SEVEN_ADAPTERS_PASSED");return 0;
}
