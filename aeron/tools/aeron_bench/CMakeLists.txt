cmake_minimum_required(VERSION 3.16)
project(aeron_bench CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Aeron itself builds as C++11; this tool is C++17 to match nats/ and fast-dds/. Mixing is
# fine (same gcc, same libstdc++) — the standard level only affects our own translation
# unit, and Aeron's headers are C++11 code that compiles unchanged under C++17.

set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

# This links the C++ WRAPPER API, not the classic C++ client.
#
# Aeron shipped two C++ APIs. The classic one (libaeron_client, headers directly in
# include/) was removed in 1.50; from 1.50 onward the supported surface is a HEADER-ONLY
# wrapper in include/wrapper that calls the C client (libaeron). So there is no
# `libaeron_client_wrapper` to link — the header path selects the API, and the actual
# symbols come from libaeron. Getting this backwards produces a confusing failure: the
# headers are found (both APIs name their entry header Aeron.h) and then every symbol is
# undefined at link time.
#
# find_library/find_path rather than find_package(aeron): Aeron does export CMake targets,
# but a wrong guess about the exported target's name fails at CONFIGURE time inside a
# Docker layer that already spent ten minutes compiling Aeron. The two paths below are
# checked explicitly and fail with a message that says what to fix.
find_path(AERON_INCLUDE_DIR
    NAMES Aeron.h
    PATHS /usr/local/include/wrapper
    NO_DEFAULT_PATH)
if(NOT AERON_INCLUDE_DIR)
    message(FATAL_ERROR
        "Aeron.h not found under /usr/local/include/wrapper. Either the Aeron build in "
        "docker/aeron-bench/Dockerfile did not install, or AERON_VERSION was moved back to "
        "a release that predates the C++ wrapper API (pre-1.50).")
endif()

# The wrapper's own headers #include <aeronc.h> — it is a thin C++ layer over the C API, so
# the C client's public header directory has to be on the include path too. Missing this
# does not fail in our code, it fails inside wrapper/util/Exceptions.h, which reads like an
# Aeron installation problem rather than a missing include directory.
find_path(AERON_C_INCLUDE_DIR
    NAMES aeronc.h
    PATHS /usr/local/include/aeron /usr/local/include
    NO_DEFAULT_PATH)
if(NOT AERON_C_INCLUDE_DIR)
    message(FATAL_ERROR "aeronc.h (the Aeron C client header) not found under /usr/local/include.")
endif()

find_library(AERON_C_LIB
    NAMES aeron
    PATHS /usr/local/lib /usr/local/lib64
    NO_DEFAULT_PATH)
if(NOT AERON_C_LIB)
    message(FATAL_ERROR
        "libaeron not found under /usr/local/lib{,64}. The wrapper API is header-only and "
        "needs the C client for its symbols.")
endif()

# Baked in by the Dockerfile from its AERON_VERSION arg, so result.json records exactly
# which Aeron produced the numbers. See the Dockerfile for why this is not read from the
# library at runtime.
set(AERON_BENCH_AERON_VERSION "unknown" CACHE STRING "Aeron version string to record in result.json")

add_executable(aeron_bench main.cpp)
target_include_directories(aeron_bench PRIVATE ${AERON_INCLUDE_DIR} ${AERON_C_INCLUDE_DIR})
target_compile_definitions(aeron_bench PRIVATE
    AERON_BENCH_AERON_VERSION="${AERON_BENCH_AERON_VERSION}")
# ${CMAKE_DL_LIBS}: the Aeron C client pulls in dlopen/dladdr on Linux.
target_link_libraries(aeron_bench PRIVATE
    ${AERON_C_LIB} Threads::Threads ${CMAKE_DL_LIBS})

install(TARGETS aeron_bench RUNTIME DESTINATION bin)
