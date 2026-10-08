cmake_minimum_required(VERSION 3.28)
project(relm_grammar_bridge LANGUAGES CXX)
add_library(relm-grammar STATIC grammar.cpp abi.cpp spill_lease.cpp projection.cpp)
target_compile_features(relm-grammar PRIVATE cxx_std_17)
set_target_properties(relm-grammar PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(relm-grammar PRIVATE
    "${RELM_LLAMA_SOURCE}/include"
    "${RELM_LLAMA_SOURCE}/src"
    "${RELM_LLAMA_SOURCE}/tools/mtmd"
    "${RELM_LLAMA_SOURCE}/ggml/include")
install(TARGETS relm-grammar ARCHIVE DESTINATION lib)
