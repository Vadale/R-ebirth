# CMAKE_PROJECT_INCLUDE hook: only the affected C source gets missing MinGW
# declarations. Source bytes and all other compile units remain unchanged.
if(NOT WIN32 OR NOT CMAKE_C_COMPILER_ID MATCHES "^(GNU|Clang)$")
    return()
endif()
include_guard(GLOBAL)

function(relm_windows_thread_declarations)
    if(NOT TARGET ggml-cpu)
        message(FATAL_ERROR "Expected ggml-cpu target for Windows compatibility")
    endif()
    set_property(SOURCE "${CMAKE_SOURCE_DIR}/ggml/src/ggml-cpu/ggml-cpu.c"
        TARGET_DIRECTORY ggml-cpu APPEND PROPERTY COMPILE_OPTIONS
        "-include" "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/windows_thread_compat.h")
endfunction()

# The root project hook runs before add_subdirectory creates ggml-cpu.
cmake_language(DEFER CALL relm_windows_thread_declarations)
