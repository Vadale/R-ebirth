// Focused test of the actual pinned loader template; no model/backend execution.
// Logger/format boundaries are captured locally. Unused loader functions are
// discarded at link time; no metadata getter or model loading function is used.
#ifndef RELM_LOADER_SOURCE
#define RELM_LOADER_SOURCE "../../rebirth/src/llama.cpp/src/llama-model-loader.cpp"
#endif
#include RELM_LOADER_SOURCE
#include <cstdarg>
#include <cstdio>
#include <iostream>

static std::string observed_log;
static std::string message(const char * fmt, va_list args) {
    char buffer[4096];
    const int n = vsnprintf(buffer, sizeof(buffer), fmt, args);
    if (n < 0 || static_cast<size_t>(n) >= sizeof(buffer)) std::abort();
    return std::string(buffer, static_cast<size_t>(n));
}
void llama_log_internal(ggml_log_level level, const char * fmt, ...) {
    va_list args; va_start(args, fmt);
    observed_log += std::to_string(level) + ":" + message(fmt, args);
    va_end(args);
}
std::string format(const char * fmt, ...) {
    va_list args; va_start(args, fmt);
    const auto result = message(fmt, args);
    va_end(args); return result;
}
static std::string hex(const std::string & value) {
    static const char digits[] = "0123456789abcdef";
    std::string output;
    for (unsigned char c : value) { output += digits[c >> 4]; output += digits[c & 15]; }
    return output;
}
static void verify(const char * name, const llama_model_kv_override * value,
                   bool expected, const std::string & expected_text,
                   const std::string & expected_log) {
    std::string target = "unchanged"; observed_log.clear();
    const bool result = GGUFMeta::GKV<std::string>::try_override<std::string>(target, value);
    if (result != expected || target != expected_text || observed_log != expected_log) std::abort();
    std::cout << name << ' ' << result << ' ' << hex(target) << ' ' << hex(observed_log) << '\n';
}
int main() {
    verify("absent", nullptr, false, "unchanged", "");
    llama_model_kv_override value{};
    std::strcpy(value.key, "probe");
    const llama_model_kv_override_type types[] = {LLAMA_KV_OVERRIDE_TYPE_BOOL,
        LLAMA_KV_OVERRIDE_TYPE_INT, LLAMA_KV_OVERRIDE_TYPE_FLOAT};
    for (auto type : types) {
        value.tag = type;
        const auto name = GGUFMeta::GKV<std::string>::override_type_to_str(type);
        verify(name, &value, false, "unchanged", std::to_string(GGML_LOG_LEVEL_WARN) +
            ":validate_override: Warning: Bad metadata override type for key 'probe', expected str but got " + name + "\n");
    }
    const std::string values[] = {"", "metadata value", std::string(127, 'x'), std::string("left\0right", 10)};
    for (size_t i = 0; i < 4; ++i) {
        value.tag = LLAMA_KV_OVERRIDE_TYPE_STR;
        std::memset(value.val_str, 0, sizeof(value.val_str));
        std::memcpy(value.val_str, values[i].data(), values[i].size());
        const std::string expected(value.val_str);
        verify(("string" + std::to_string(i)).c_str(), &value, true, expected,
            std::to_string(GGML_LOG_LEVEL_INFO) + ":validate_override: Using metadata override (  str) 'probe' = " +
            std::to_string(GGML_LOG_LEVEL_INFO) + ":" + expected + "\n");
    }
    std::cout << "CRAN_LOADER_OVERRIDE_OK cases=8 absent=1 wrong_type=3 valid=4 model_loads=0\n";
}
