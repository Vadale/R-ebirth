// D046 relm-owned bridge. Pinned GGML structs stay on the C++ side.
#include "projection.h"
#include "ggml.h"
#include "ggml-backend.h"
#include <cstdio>
#include <cstring>
#include <limits>

struct relm_projection_name_frame { char bytes[GGML_MAX_NAME]; };
extern "C" size_t relm_projection_name_frame_size() { return sizeof(relm_projection_name_frame); }
static bool named(const ggml_tensor * t, const char * role, uint32_t layer) {
    if (!t) return false;
    relm_projection_name_frame frame{};
    auto & expected = frame.bytes;
    const int n = std::snprintf(expected, sizeof(expected), "blk.%u.%s", layer, role);
    return n > 0 && size_t(n) < sizeof(expected) && std::strcmp(t->name, expected) == 0;
}
static bool activation_name(const ggml_tensor * t, const char * role, uint32_t layer) {
    if (!t) return false;
    relm_projection_name_frame frame{};
    auto & expected = frame.bytes;
    const int n = std::snprintf(expected, sizeof(expected), "%s-%u", role, layer);
    return n > 0 && size_t(n) < sizeof(expected) && std::strcmp(t->name, expected) == 0;
}
static bool shape(const ggml_tensor * t, size_t h) {
    return t && h && h <= 65536 && t->type == GGML_TYPE_F32 && t->ne[0] == int64_t(h)
        && t->ne[1] >= 0 && t->ne[2] == 1 && t->ne[3] == 1
        && !t->view_src && t->view_offs == 0 && ggml_is_contiguous(t)
        && !(t->flags & (GGML_TENSOR_FLAG_INPUT | GGML_TENSOR_FLAG_PARAM));
}
static bool weight(const ggml_tensor * t, const char * role, uint32_t layer) {
    return t && t->op == GGML_OP_NONE && !t->view_src && named(t, role, layer);
}
static bool overlap(const ggml_tensor * a, const ggml_tensor * b) {
    if (!a || !b || !a->data || !b->data) return false;
    const uintptr_t x = reinterpret_cast<uintptr_t>(a->data), y = reinterpret_cast<uintptr_t>(b->data);
    const size_t nx = ggml_nbytes(a), ny = ggml_nbytes(b);
    if (nx > UINTPTR_MAX-x || ny > UINTPTR_MAX-y) return true;
    return nx && ny && x < y+ny && y < x+nx;
}
extern "C" int relm_projection_classify(const ggml_tensor * t, uint32_t layer,
        uint32_t component, size_t h, bool ready, relm_projection_info * out) {
    if (!out || component > 1 || !shape(t,h)) return -1;
    // component 0 = MLP, 1 = post-Wo attention.
    const char * base = component == 0 ? "ffn_down.weight" : "attn_output.weight";
    const char * bias = component == 0 ? "ffn_down.bias" : "attn_output.bias";
    const char * scale = component == 0 ? "ffn_down.scale" : "attn_output.scale";
    const ggml_tensor * cur = t;
    uint32_t wrappers = 0;
    // Recognize the exact residual duplicate, not an arbitrary activation ADD.
    if (component == 0 && cur->op == GGML_OP_ADD &&
        activation_name(cur->src[1], "ffn_inp", layer)) return 1;
    // MLP: scale(bias(matmul)); attention: bias(scale(matmul)).
    for (int i=0; i<2; ++i) {
        const bool is_bias = component == 0 ? i == 1 : i == 0;
        const ggml_op op = is_bias ? GGML_OP_ADD : GGML_OP_MUL;
        if (cur->op != op) continue;
        const ggml_tensor * operand = cur->src[1];
        if (!weight(operand, is_bias ? bias : scale, layer) || !shape(cur->src[0], h)
            || operand->ne[0] != int64_t(h) || ggml_nrows(operand) != 1) return -2;
        if (ready && (overlap(t, cur->src[0]) || overlap(t, operand))) return -3;
        cur = cur->src[0];
        ++wrappers;
    }
    if (cur->op != GGML_OP_MUL_MAT || !weight(cur->src[0],base,layer)
        || !cur->src[1] || cur->src[0]->ne[1] != int64_t(h)
        || cur->src[0]->ne[0] != cur->src[1]->ne[0]) return -4;
    if (ready && (overlap(t, cur->src[0]) || overlap(t, cur->src[1]))) return -3;
    const uint64_t rows = uint64_t(ggml_nrows(t));
    if (rows > SIZE_MAX / (h * sizeof(float))) return -5;
    const size_t bytes = size_t(rows) * h * sizeof(float);
    if (ggml_nbytes(t) != bytes) return -5;
    const bool host = t->buffer && ggml_backend_buffer_is_host(t->buffer);
    if (ready && bytes && (!t->data || !host
        || ggml_backend_buffer_get_usage(t->buffer) == GGML_BACKEND_BUFFER_USAGE_WEIGHTS)) return -6;
    *out = { rows, uint64_t(bytes), wrappers, uint32_t(host) };
    return 0;
}
extern "C" int relm_projection_row(ggml_tensor * t, size_t h, size_t row, float * data, bool write) {
    if (!shape(t,h) || !data || row >= uint64_t(ggml_nrows(t)) || !t->buffer
        || !ggml_backend_buffer_is_host(t->buffer) || !t->data) return -1;
    if (row > SIZE_MAX / (h * sizeof(float))) return -2;
    const size_t offset = row * h * sizeof(float), bytes = h * sizeof(float);
    if (offset > ggml_nbytes(t) || bytes > ggml_nbytes(t)-offset) return -2;
    if (write) ggml_backend_tensor_set(t,data,offset,bytes);
    else ggml_backend_tensor_get(t,data,offset,bytes);
    return 0;
}
extern "C" int relm_projection_consumer(const ggml_tensor * t, uint32_t layer, uint32_t component, size_t h) {
    if (!shape(t,h) || t->op != GGML_OP_ADD) return -1;
    const ggml_tensor * producer = t->src[0];
    if (component == 1 && producer && producer->op == GGML_OP_GET_ROWS) {
        // The one-token capability probe must select exactly row zero.
        auto * ids = producer->src[1];
        if (!ids || ids->type != GGML_TYPE_I32 || ggml_nelements(ids) != 1 || !ids->buffer || !ggml_backend_buffer_is_host(ids->buffer)) return -2;
        int32_t index = -1;
        ggml_backend_tensor_get(ids,&index,0,sizeof(index));
        if (index != 0) return -2;
        producer = producer->src[0];
    }
    relm_projection_info info{};
    return relm_projection_classify(producer,layer,component,h,false,&info);
}
extern "C" size_t relm_projection_info_size() { return sizeof(relm_projection_info); }
extern "C" uint64_t relm_projection_classifier_controls() {
    ggml_init_params p { 64 * ggml_tensor_overhead(), nullptr, true };
    ggml_context * ctx = ggml_init(p);
    if (!ctx) return 0;
    auto * w = ggml_new_tensor_2d(ctx,GGML_TYPE_F32,8,4);
    auto * x = ggml_new_tensor_2d(ctx,GGML_TYPE_F32,8,2);
    ggml_set_name(w,"blk.0.ffn_down.weight");
    auto * t = ggml_mul_mat(ctx,w,x);
    relm_projection_info info{};
    uint64_t bits = relm_projection_classify(t,0,0,4,false,&info)==0 ? 1 : 0;
    bits |= uint64_t(relm_projection_classify(t,0,1,4,false,&info)<0)<<1;
    auto * residual = ggml_new_tensor_2d(ctx,GGML_TYPE_F32,4,2);
    ggml_set_name(residual,"ffn_inp-0");
    auto * add = ggml_add(ctx,t,residual);
    bits |= uint64_t(relm_projection_classify(add,0,0,4,false,&info)==1)<<2;
    auto * view = ggml_view_2d(ctx,t,4,2,16,0);
    bits |= uint64_t(relm_projection_classify(view,0,0,4,false,&info)<0)<<3;
    auto * integer = ggml_new_tensor_2d(ctx,GGML_TYPE_I32,4,2);
    bits |= uint64_t(relm_projection_classify(integer,0,0,4,false,&info)<0)<<4;
    const auto saved = t->op;
    t->op = GGML_OP_MUL_MAT_ID;
    bits |= uint64_t(relm_projection_classify(t,0,0,4,false,&info)<0)<<5;
    t->op = saved;
    ggml_set_name(w,"blk.0.attn_output.weight");
    bits |= uint64_t(relm_projection_classify(t,0,1,4,false,&info)==0)<<6;
    bits |= uint64_t(relm_projection_classify(t,0,1,5,false,&info)<0)<<7;
    auto * bias = ggml_new_tensor_1d(ctx,GGML_TYPE_F32,4);
    ggml_set_name(bias,"blk.0.attn_output.bias");
    auto * biased = ggml_add(ctx,t,bias);
    bits |= uint64_t(relm_projection_classify(biased,0,1,4,false,&info)==0)<<8;
    t->nb[1] += 4;
    bits |= uint64_t(relm_projection_classify(t,0,1,4,false,&info)<0)<<9;
    t->nb[1] -= 4;
    float storage[16]{};
    t->data = storage; x->data = storage;
    bits |= uint64_t(relm_projection_classify(t,0,1,4,true,&info)==-3)<<10;
    t->data = nullptr; x->data = nullptr;
    ggml_set_name(w,"blk.0.unrelated.weight");
    bits |= uint64_t(relm_projection_classify(t,0,1,4,false,&info)<0)<<11;
    ggml_free(ctx);
    return bits;
}
