// D046 relm-owned bridge. Pinned GGML structs stay on the C++ side.
#include "projection.h"
#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include <cstdio>
#include <cstring>
#include <limits>

// Kind 1 preserves the generic host fast path. Kind 2 is the pinned registered
// Metal device's DEFAULT SHARED type, never a name-only or private-buffer test.
struct relm_projection_access_frame {
    ggml_backend_buffer_type_t type;
    ggml_backend_dev_t device;
    ggml_backend_reg_t registry, metal_registry;
    const char * type_name;
    const char * device_name;
    const char * registry_name;
    uint32_t index, flags;
};
extern "C" size_t relm_projection_access_frame_size() {
    // The identity frame coexists with shared_identity's parsed index and one
    // bounded parser/name-copy loop index. Include the copy-completion scalar.
    return sizeof(relm_projection_access_frame)+sizeof(uint32_t)+sizeof(size_t)+sizeof(bool);
}
static bool device_index(const char * name, uint32_t & result) {
    if (!name || name[0]!='M' || name[1]!='T' || name[2]!='L' || name[3]<'0' || name[3]>'9') return false;
    if (name[3]=='0' && name[4]!=0) return false;
    result=0;
    for (size_t i=3; i<32; ++i) {
        if (!name[i]) return true;
        if (name[i]<'0' || name[i]>'9' || result>(UINT32_MAX-uint32_t(name[i]-'0'))/10) return false;
        result=result*10+uint32_t(name[i]-'0');
    }
    return false;
}
static bool same_name(const char * a, const char * b) {
    if (!a || !b) return false;
    for (size_t i=0; i<32; ++i) {
        if (a[i]!=b[i]) return false;
        if (!a[i]) return true;
    }
    return false;
}
static bool copy_name(uint8_t * dst, size_t capacity, const char * src) {
    if (!src) return false;
    for (size_t i=0; i<capacity; ++i) {
        dst[i]=uint8_t(src[i]);
        if (!src[i]) return true;
    }
    return false;
}
static bool shared_identity(uint32_t flags, const char * type, const char * device) {
    uint32_t index=0;
    return (flags & 7)==7 && (flags & 16)!=0 && device_index(device,index) && same_name(type,device);
}
static uint32_t buffer_access(ggml_backend_buffer_t buffer, relm_projection_buffer_info * proof) {
    if (!buffer) return 0;
    if (ggml_backend_buffer_is_host(buffer)) {
        if (proof) { proof->kind=1; proof->is_host=1; }
        return 1;
    }
    relm_projection_access_frame f{};
    f.type=ggml_backend_buffer_get_type(buffer);
    f.type_name=ggml_backend_buft_name(f.type);
    f.device=ggml_backend_buft_get_device(f.type);
    if (!f.device) return 0;
    f.device_name=ggml_backend_dev_name(f.device);
    f.registry=ggml_backend_dev_backend_reg(f.device);
    f.metal_registry=ggml_backend_reg_by_name("MTL");
    f.registry_name=f.registry ? ggml_backend_reg_name(f.registry) : nullptr;
    if (f.registry && f.registry==f.metal_registry) f.flags|=1;
    if (ggml_backend_dev_type(f.device)==GGML_BACKEND_DEVICE_TYPE_GPU) f.flags|=16;
    if ((f.flags&1) && device_index(f.device_name,f.index)
        && f.index<ggml_backend_reg_dev_count(f.registry)
        && ggml_backend_reg_dev_get(f.registry,f.index)==f.device) {
        f.flags|=4;
        if (ggml_backend_dev_buffer_type(f.device)==f.type) f.flags|=2;
    }
    if (same_name(f.type_name,f.device_name)) f.flags|=8;
    const uint32_t kind=shared_identity(f.flags,f.type_name,f.device_name) ? 2 : 0;
    if (proof) {
        proof->kind=kind;
        proof->device_type=uint32_t(ggml_backend_dev_type(f.device));
        proof->device_index=f.index;
        proof->flags=f.flags;
        bool complete=copy_name(proof->type_name,sizeof(proof->type_name),f.type_name);
        complete=copy_name(proof->device_name,sizeof(proof->device_name),f.device_name) && complete;
        complete=copy_name(proof->registry_name,sizeof(proof->registry_name),f.registry_name) && complete;
        if (complete) proof->flags|=32;
    }
    // Pinned proof: the default shared singleton is selected only when the
    // initialized immutable use_shared_buffers property is true. Its allocator
    // passes true AND that same property, so it cannot take the private fallback.
    // Shared get/set are memcpy; no staging objects or per-row allocation.
    return kind;
}

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
    *out = { rows, uint64_t(bytes), wrappers, 0, {} };
    out->access=buffer_access(t->buffer,&out->buffer);
    if (t->data) out->buffer.flags|=64;
    out->buffer.flags|=128; // shape() already proved contiguous, non-view F32.
    if (t->buffer) out->buffer.usage=uint32_t(ggml_backend_buffer_get_usage(t->buffer));
    if (ready && bytes && (!t->data || !out->access
        || ggml_backend_buffer_get_usage(t->buffer) == GGML_BACKEND_BUFFER_USAGE_WEIGHTS)) return -6;
    return 0;
}
extern "C" int relm_projection_row(ggml_tensor * t, size_t h, size_t row, float * data, bool write) {
    if (!shape(t,h) || !data || row >= uint64_t(ggml_nrows(t)) || !t->buffer
        || !buffer_access(t->buffer,nullptr) || !t->data
        || ggml_backend_buffer_get_usage(t->buffer)==GGML_BACKEND_BUFFER_USAGE_WEIGHTS) return -1;
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
        if (!ids || ids->type != GGML_TYPE_I32 || ggml_nelements(ids) != 1 || !ids->buffer || !buffer_access(ids->buffer,nullptr)) return -2;
        int32_t index = -1;
        ggml_backend_tensor_get(ids,&index,0,sizeof(index));
        if (index != 0) return -2;
        producer = producer->src[0];
    }
    relm_projection_info info{};
    return relm_projection_classify(producer,layer,component,h,false,&info);
}
extern "C" size_t relm_projection_info_size() { return sizeof(relm_projection_info); }
extern "C" uint64_t relm_projection_buffer_controls() {
    uint64_t bits=0;
    const uint32_t valid=1|2|4|8|16;
    bits|=uint64_t(shared_identity(valid,"MTL0","MTL0"))<<0;
    bits|=uint64_t(shared_identity(valid,"MTL15","MTL15"))<<1;
    bits|=uint64_t(!shared_identity(valid,"MTL0_Private","MTL0"))<<2;
    bits|=uint64_t(!shared_identity(valid,"MTL0_Mapped","MTL0"))<<3;
    bits|=uint64_t(!shared_identity(valid&~1u,"MTL0","MTL0"))<<4;
    bits|=uint64_t(!shared_identity(valid&~2u,"MTL0","MTL0"))<<5;
    bits|=uint64_t(!shared_identity(valid&~4u,"MTL0","MTL0"))<<6;
    bits|=uint64_t(!shared_identity(valid&~16u,"MTL0","MTL0"))<<7;
    bits|=uint64_t(!shared_identity(valid,"MTL1","MTL0"))<<8;
    bits|=uint64_t(!shared_identity(valid,"MTL","MTL"))<<9;
    bits|=uint64_t(!shared_identity(valid,"MTL01","MTL01"))<<10;
    bits|=uint64_t(!shared_identity(valid,"MTL0_Private","MTL0_Private"))<<11;
    bits|=uint64_t(!shared_identity(valid,nullptr,"MTL0"))<<12;
    bits|=uint64_t(!buffer_access(nullptr,nullptr))<<13;
    // Actual host allocation proves that the new path preserves the early host
    // verdict without a Metal registry/device lookup or staging operation.
    auto * host_type=ggml_backend_cpu_buffer_type();
    auto * host=ggml_backend_buft_alloc_buffer(host_type,64);
    relm_projection_buffer_info proof{};
    bits|=uint64_t(host && buffer_access(host,&proof)==1 && proof.is_host==1 && proof.flags==0)<<14;
    if (host) {
        ggml_tensor row_tensor{};
        row_tensor.type=GGML_TYPE_F32;
        row_tensor.ne[0]=4;
        row_tensor.nb[0]=sizeof(float);
        for (int i=1; i<GGML_MAX_DIMS; ++i) {
            row_tensor.ne[i]=1;
            row_tensor.nb[i]=4*sizeof(float);
        }
        row_tensor.buffer=host;
        row_tensor.data=ggml_backend_buffer_get_base(host);
        float row[4]={1,-2,3,-4}, copied[4]{};
        bits|=uint64_t(relm_projection_row(&row_tensor,4,0,row,true)==0
            && relm_projection_row(&row_tensor,4,0,copied,false)==0
            && std::memcmp(row,copied,sizeof(row))==0)<<18;
        bits|=uint64_t(relm_projection_row(&row_tensor,4,1,row,true)==-1)<<20;
        ggml_backend_buffer_set_usage(host,GGML_BACKEND_BUFFER_USAGE_WEIGHTS);
        bits|=uint64_t(relm_projection_row(&row_tensor,4,0,row,true)==-1
            && relm_projection_row(&row_tensor,4,0,copied,false)==-1)<<19;
    }
    ggml_backend_buffer_free(host);
    bits|=uint64_t(!shared_identity(valid,"Other0","Other0"))<<15;
    bits|=uint64_t(!shared_identity(valid,"MTL42949672960","MTL42949672960"))<<16;
    bits|=uint64_t(!shared_identity(valid,"MTL0_Mapped","MTL0_Mapped"))<<17;
    return bits;
}
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
