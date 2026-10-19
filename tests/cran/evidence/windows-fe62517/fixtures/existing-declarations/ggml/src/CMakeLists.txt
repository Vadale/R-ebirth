add_executable(ggml-cpu ggml-cpu/ggml-cpu.c unaffected.c)
target_include_directories(ggml-cpu PRIVATE "${CMAKE_SOURCE_DIR}/headers" "/home/grauk/Documents/Codex/Recupero-Mac-2026-10-13/DOCUDESK/R-ebirth/rebirth/src/llama.cpp/ggml/include")
target_compile_definitions(ggml-cpu PRIVATE _WIN32 __MINGW32__ _WIN32_WINNT=0x0602)
target_compile_options(ggml-cpu PRIVATE -std=c11 -Wall -Wextra -Werror -pedantic)
