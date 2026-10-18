add_executable(ggml-cpu ggml-cpu/ggml-cpu.c unaffected.c)
target_include_directories(ggml-cpu PRIVATE "${CMAKE_SOURCE_DIR}/headers")
target_compile_definitions(ggml-cpu PRIVATE _WIN32 __MINGW32__)
target_compile_options(ggml-cpu PRIVATE -std=c11 -Wall -Wextra -Werror -pedantic)
