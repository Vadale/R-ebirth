// Relm-owned exception boundary; the vendored engine remains unchanged.
#include "llama.h"
#include "llama-grammar.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace {
struct grammar_state {
    llama_sampler * sampler = nullptr;
    std::vector<llama_token_data> candidates;
    std::vector<llama_token_data> eog;
    ~grammar_state() { llama_sampler_free(sampler); }
};

bool bounded_grammar(const char * text, size_t limit) {
    llama_grammar_parser parser;
    if (!parser.parse(text)) return false;
    size_t count = 0;
    for (const auto & rule : parser.rules) {
        if (rule.size() > limit - count) return false;
        count += rule.size();
    }
    return true;
}
}

extern "C" void * relm_grammar_new(const llama_vocab * vocab, const char * text,
                                   size_t element_limit) noexcept {
    try {
        if (!bounded_grammar(text, element_limit)) return nullptr;
        auto state = std::make_unique<grammar_state>();
        state->sampler = llama_sampler_init_grammar(vocab, text, "root");
        if (!state->sampler) return nullptr;
        const auto n = llama_vocab_n_tokens(vocab);
        if (n <= 0) return nullptr;
        state->candidates.resize(static_cast<size_t>(n));
        for (llama_token id = 0; id < n; ++id) {
            if (llama_vocab_is_eog(vocab, id)) state->eog.push_back({id, 0.0f, 0.0f});
        }
        if (state->eog.empty()) return nullptr;
        return state.release();
    } catch (...) { return nullptr; }
}

extern "C" int relm_grammar_mask(void * handle, float * logits, size_t n, bool greedy) noexcept {
    try {
        auto & state = *static_cast<grammar_state *>(handle);
        if (n != state.candidates.size()) return -1;
        for (size_t i = 0; i < n; ++i)
            state.candidates[i] = {static_cast<llama_token>(i), logits[i], 0.0f};
        if (greedy) {
            // Exactly the existing argmax order, including equal +/-0 logits.
            // The first admissible entry is the result of a complete mask plus
            // argmax. No probabilities or random draws are involved.
            std::sort(state.candidates.begin(), state.candidates.end(), [](const auto & a, const auto & b) {
                return a.logit == b.logit ? a.id < b.id : a.logit > b.logit;
            });
        }
        // Upstream allocates decoded strings and rejection stacks per candidate.
        // Small independent batches bound that scratch memory; apply never
        // accepts a token or changes the grammar state.
        constexpr size_t chunk_capacity = 512;
        const size_t chunk_size = greedy ? 32 : chunk_capacity;
        std::array<llama_token, chunk_capacity> ids{};
        for (size_t offset = 0; offset < n; offset += chunk_size) {
            const size_t count = std::min(chunk_size, n - offset);
            auto * data = state.candidates.data() + offset;
            for (size_t i = 0; i < count; ++i) ids[i] = data[i].id;
            llama_token_data_array array{data, count, -1, false};
            llama_sampler_apply(state.sampler, &array);
            if (array.data != data || array.size != count) return -1;
            for (size_t i = 0; i < count; ++i) {
                if (data[i].id != ids[i]) return -1;
                if (greedy && std::isfinite(data[i].logit)) {
                    const auto selected = data[i];
                    std::fill(logits, logits + n, -std::numeric_limits<float>::infinity());
                    logits[selected.id] = selected.logit;
                    return 0;
                }
                if (!greedy) logits[ids[i]] = data[i].logit;
            }
        }
        if (greedy) std::fill(logits, logits + n, -std::numeric_limits<float>::infinity());
        return 0;
    } catch (...) { return -1; }
}

extern "C" void * relm_grammar_clone(const void * handle) noexcept {
    try {
        const auto & source = *static_cast<const grammar_state *>(handle);
        auto state = std::make_unique<grammar_state>();
        state->sampler = llama_sampler_clone(source.sampler);
        if (!state->sampler) return nullptr;
        state->candidates.resize(source.candidates.size());
        state->eog = source.eog;
        return state.release();
    } catch (...) { return nullptr; }
}

extern "C" int relm_grammar_complete(void * handle) noexcept {
    try {
        auto & state = *static_cast<grammar_state *>(handle);
        for (auto & token : state.eog) token.logit = 0.0f;
        llama_token_data_array array{state.eog.data(), state.eog.size(), -1, false};
        llama_sampler_apply(state.sampler, &array);
        for (size_t i = 0; i < array.size; ++i)
            if (std::isfinite(array.data[i].logit)) return 1;
        return 0;
    } catch (...) { return -1; }
}

extern "C" int relm_grammar_accept(void * handle, llama_token token) noexcept {
    try {
        llama_sampler_accept(static_cast<grammar_state *>(handle)->sampler, token);
        return 0;
    } catch (...) { return -1; }
}

extern "C" void relm_grammar_free(void * handle) noexcept {
    delete static_cast<grammar_state *>(handle);
}

// R-free acceptance oracle for generated grammar fixtures: the upstream parser
// and code-point automaton, independently of relm's output validator/tokenizer.
extern "C" int relm_grammar_check(const char * text, const uint32_t * chars,
                                  size_t n, size_t limit) noexcept {
    try {
        if (!bounded_grammar(text, limit)) return -1;
        std::unique_ptr<llama_grammar, decltype(&llama_grammar_free_impl)> grammar(
            llama_grammar_init_impl(nullptr, text, "root", false, nullptr, 0, nullptr, 0),
            &llama_grammar_free_impl);
        if (!grammar) return -1;
        for (size_t i = 0; i < n; ++i) {
            llama_grammar_accept(grammar.get(), chars[i]);
            if (llama_grammar_get_stacks(grammar.get()).empty()) return 0;
        }
        for (const auto & stack : llama_grammar_get_stacks(grammar.get()))
            if (stack.empty()) return 1;
        return 0;
    } catch (...) { return -1; }
}
