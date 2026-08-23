cmake_minimum_required(VERSION 3.16)
project(dds_bench CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Same class of pitfall as cnats in nats/tools/latency_oneway: the imported Fast DDS target
# references Threads::Threads in its link interface, so Threads must be found first or the
# find_package below fails to resolve it.
set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

# Fast DDS 2.x exports its CMake package as "fastrtps" (target `fastrtps`), NOT "fastdds" —
# that rename only happens in Fast DDS 3.x, which also changes the TopicDataType API this
# tool implements. The Dockerfile pins 2.14.x deliberately; see CLAUDE.md.
find_package(fastcdr REQUIRED)
find_package(fastrtps REQUIRED)

add_executable(dds_bench main.cpp)
target_link_libraries(dds_bench PRIVATE fastrtps fastcdr Threads::Threads)

install(TARGETS dds_bench RUNTIME DESTINATION bin)
