cmake_minimum_required(VERSION 3.10)
project(latency_oneway CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# cnats::nats_static's link interface references Threads::Threads, so Threads must be
# found first or CMake fails to resolve that imported target when configuring cnats.
set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

# nats.c's CMake package is exported as "cnats" (not "NATS"), with imported targets
# cnats::nats (shared) / cnats::nats_static (static) — confirmed from the actual
# installed cnats-config.cmake, not from the README (which is misleading here).
find_package(cnats REQUIRED)

add_executable(latency_oneway main_v2.cpp)

# Static-link nats.c so the container image doesn't need libnats.so on the runtime
# PATH/LD_LIBRARY_PATH at execution time; pthread/rt/dl are nats.c's own transitive
# link requirements on Linux.
target_link_libraries(latency_oneway PRIVATE cnats::nats_static pthread rt dl)

install(TARGETS latency_oneway RUNTIME DESTINATION bin)
