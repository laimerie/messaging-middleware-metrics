# aeron-bench: the single "host client" image for every Aeron benchmark in this project.
# It bundles our own aeron_bench binary (throughput / one-way latency / RTT), Aeron's C
# media driver (`aeronmd`), and `tc` for netem delay injection — so the same image drives
# same-container runs (bench-*.sh), cross-container runs (bench-crosshost.sh), and the
# two-real-server runs (bench-rtt-2host.sh).
#
# Built to match the production runtime — CentOS 7 / gcc 11 / C++17, identical to
# nats/docker/latency-tool/Dockerfile and fast-dds/docker/dds-bench/Dockerfile — so all
# three projects' numbers are comparable and none carries client-runtime overhead the
# others don't.
#
# CentOS 7 reached EOL in June 2024: mirrorlist.centos.org is gone, so both the base and
# SCL repos are repointed at vault.centos.org below before any yum install runs.
FROM centos:7

# --- Fix EOL yum repos (base) --------------------------------------------------------
RUN sed -i \
      -e 's/^mirrorlist=/#mirrorlist=/' \
      -e 's/^#baseurl=http:\/\/mirror\.centos\.org/baseurl=http:\/\/vault.centos.org/' \
      /etc/yum.repos.d/CentOS-*.repo

# --- devtoolset-11 (gcc 11) via Software Collections ----------------------------------
# Note: the SCLo repo files use inconsistent comment spacing ("#baseurl=" in one file,
# "# baseurl=" in the other) — the [[:space:]]* handles both.
#
# libuuid-devel is an Aeron-specific addition: the C media driver links libuuid on Linux
# (aeron-driver/src/main/c/CMakeLists.txt links `uuid` when it is found). It is a silent
# feature-detection, not a hard error — without the headers CMake simply does not find it,
# and you only notice later.
RUN yum install -y centos-release-scl-rh centos-release-scl && \
    sed -i \
      -e 's/^mirrorlist=/#mirrorlist=/' \
      -re 's|^#[[:space:]]*baseurl=http://mirror\.centos\.org|baseurl=http://vault.centos.org|' \
      /etc/yum.repos.d/CentOS-SCLo-scl*.repo && \
    yum install -y devtoolset-11-gcc devtoolset-11-gcc-c++ devtoolset-11-make \
      git curl make iproute libuuid-devel && \
    yum clean all
# iproute: provides `tc`, used by entrypoint.sh for netem delay injection.

ENV PATH=/opt/rh/devtoolset-11/root/usr/bin:$PATH \
    LD_LIBRARY_PATH=/opt/rh/devtoolset-11/root/usr/lib64:$LD_LIBRARY_PATH

# --- CMake ---------------------------------------------------------------------------
# CentOS 7's yum cmake is 2.8. Aeron's top-level CMakeLists.txt declares
# `cmake_minimum_required(VERSION 3.30 FATAL_ERROR)` from the 1.48 line onward — note that
# this is NEWER than the 3.27.9 the fast-dds image pins, so the two Dockerfiles genuinely
# need different CMake versions. Do not "unify" them without checking Aeron's requirement.
ARG CMAKE_VERSION=3.31.6
RUN curl -fsSL -o /tmp/cmake.tar.gz \
      https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz && \
    tar -xzf /tmp/cmake.tar.gz -C /opt && \
    ln -s /opt/cmake-${CMAKE_VERSION}-linux-x86_64/bin/cmake /usr/local/bin/cmake && \
    ln -s /opt/cmake-${CMAKE_VERSION}-linux-x86_64/bin/ctest /usr/local/bin/ctest && \
    rm /tmp/cmake.tar.gz

# --- Aeron (C++ client + C media driver) ---------------------------------------------
# Three of these flags are load-bearing, not tidiness:
#
#   BUILD_AERON_ARCHIVE_API=OFF  The Archive API is a JAVA component: with it ON, the
#                                CMake build shells out to `gradlew` and needs a JDK.
#                                Aeron Archive is durable stream recording/replay — a
#                                different product concern from the transport this project
#                                measures — so this both cuts the dependency and keeps the
#                                scope honest.
#   AERON_TESTS/UNIT/SYSTEM=OFF  Otherwise the configure step downloads GoogleTest from the
#                                network at build time.
#   BUILD_AERON_DRIVER=ON        This is what produces `aeronmd`. Aeron is NOT daemonless:
#                                every host that runs an Aeron application also runs a
#                                media driver, and without this binary nothing works at all.
#
# Version pinning: the repo moved from github.com/real-logic/aeron to
# github.com/aeron-io/aeron. Both currently resolve, but the aeron-io path is the canonical
# one now.
#
# WHICH C++ API. Aeron has two, and picking the wrong one dates this project immediately:
#   * the CLASSIC C++ client (aeron-client/src/main/cpp, libaeron_client, headers in
#     include/) — a full native C++ implementation. Building against 1.48 emits
#     "The C++ API will be removed in 1.50.0!", and it is indeed gone from 1.50 onward.
#   * the C++ WRAPPER (aeron-client/src/main/cpp_wrapper, headers in include/wrapper) — a
#     header-only C++ surface over the C client (libaeron). This is the supported path.
# tools/aeron_bench links the wrapper, so this pin must stay on a version that HAS it.
# Verified: 1.52.2 builds clean on CentOS 7 / gcc 11 with the flags below.
ARG AERON_VERSION=1.52.2
RUN git clone --depth 1 --branch ${AERON_VERSION} \
      https://github.com/aeron-io/aeron.git /opt/aeron && \
    cmake -S /opt/aeron -B /opt/aeron/build \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_AERON_DRIVER=ON \
      -DBUILD_AERON_ARCHIVE_API=OFF \
      -DAERON_TESTS=OFF \
      -DAERON_UNIT_TESTS=OFF \
      -DAERON_SYSTEM_TESTS=OFF \
      -DAERON_BUILD_SAMPLES=OFF \
      -DAERON_BUILD_DOCUMENTATION=OFF \
      -DAERON_INSTALL_TARGETS=ON && \
    cmake --build /opt/aeron/build --target install -- -j$(nproc)

# CMake installs into /usr/local/lib (and lib64 on some generators), neither of which is on
# CentOS 7's default loader path — without this, aeronmd dies with
# "libaeron_driver.so: cannot open shared object file".
RUN printf '/usr/local/lib\n/usr/local/lib64\n' > /etc/ld.so.conf.d/aeron.conf && ldconfig

# --- Build our own benchmark tool -----------------------------------------------------
# AERON_VERSION is baked in as a compile definition rather than read back from the library
# at runtime: it is exact by construction and costs no API surface. The C++ client's own
# version accessor has moved between releases, so reading it would be one more thing to
# re-verify on every version bump.
WORKDIR /opt/aeron_bench
COPY tools/aeron_bench/ .
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
      -DAERON_BENCH_AERON_VERSION="${AERON_VERSION}" && \
    cmake --build build --target install -- -j$(nproc)

# lib/aeron-driver.sh is the media driver's lifecycle, shared verbatim with the NATIVE
# execution path (scripts/common-native.sh) used on servers that cannot run Docker. It is at
# the project's top level rather than under scripts/ precisely so it stays inside the build
# context - .dockerignore excludes scripts/.
COPY lib/aeron-driver.sh /usr/local/lib/aeron-driver.sh
COPY docker/aeron-bench/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# No fixed binary: this image runs `aeron_bench ...` or `aeronmd` depending on what the
# calling script passes (see scripts/bench-*.sh).
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
