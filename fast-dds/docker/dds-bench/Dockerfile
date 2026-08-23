# dds-bench: the single "host client" image for every Fast DDS benchmark in this project.
# It bundles our own dds_bench binary (throughput / one-way latency / RTT) and eProsima's
# `fast-discovery-server`, and can inject artificial network latency via tc netem — so the
# same image drives same-host runs (bench-*.sh), cross-container runs (bench-crosshost.sh),
# and the optional Discovery Server (start-discovery-server.sh).
#
# Built to match the production runtime — CentOS 7 / gcc 11 / C++17, identical to
# nats/docker/latency-tool/Dockerfile — so the two projects' numbers are comparable and
# neither carries client-runtime overhead the other doesn't.
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
RUN yum install -y centos-release-scl-rh centos-release-scl && \
    sed -i \
      -e 's/^mirrorlist=/#mirrorlist=/' \
      -re 's|^#[[:space:]]*baseurl=http://mirror\.centos\.org|baseurl=http://vault.centos.org|' \
      /etc/yum.repos.d/CentOS-SCLo-scl*.repo && \
    yum install -y devtoolset-11-gcc devtoolset-11-gcc-c++ devtoolset-11-make \
      git curl make iproute && \
    yum clean all
# iproute: provides `tc`, used by entrypoint.sh for netem delay injection.

ENV PATH=/opt/rh/devtoolset-11/root/usr/bin:$PATH \
    LD_LIBRARY_PATH=/opt/rh/devtoolset-11/root/usr/lib64:$LD_LIBRARY_PATH

# --- CMake (CentOS 7's yum cmake is 2.8; Fast DDS needs 3.20+) -------------------------
ARG CMAKE_VERSION=3.27.9
RUN curl -fsSL -o /tmp/cmake.tar.gz \
      https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz && \
    tar -xzf /tmp/cmake.tar.gz -C /opt && \
    ln -s /opt/cmake-${CMAKE_VERSION}-linux-x86_64/bin/cmake /usr/local/bin/cmake && \
    ln -s /opt/cmake-${CMAKE_VERSION}-linux-x86_64/bin/ctest /usr/local/bin/ctest && \
    rm /tmp/cmake.tar.gz

# --- Fast DDS dependency chain --------------------------------------------------------
# Version pinning matters here beyond reproducibility: Fast DDS 3.x renames the exported
# CMake package (fastrtps -> fastdds) AND changes the TopicDataType virtual interface that
# tools/dds_bench/main.cpp implements by hand. Staying on the 2.14 line keeps that
# interface stable. Fast DDS 2.14 pairs with Fast CDR 2.x.
ARG FOONATHAN_MEMORY_VENDOR_VERSION=v1.3.1
RUN git clone --depth 1 --branch ${FOONATHAN_MEMORY_VENDOR_VERSION} \
      https://github.com/eProsima/foonathan_memory_vendor.git /opt/foonathan_memory_vendor && \
    cmake -S /opt/foonathan_memory_vendor -B /opt/foonathan_memory_vendor/build \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF && \
    cmake --build /opt/foonathan_memory_vendor/build --target install -- -j$(nproc)

ARG FASTCDR_VERSION=v2.2.4
RUN git clone --depth 1 --branch ${FASTCDR_VERSION} \
      https://github.com/eProsima/Fast-CDR.git /opt/Fast-CDR && \
    cmake -S /opt/Fast-CDR -B /opt/Fast-CDR/build -DCMAKE_BUILD_TYPE=Release && \
    cmake --build /opt/Fast-CDR/build --target install -- -j$(nproc)

# THIRDPARTY=ON uses the bundled asio / tinyxml2 / taocpp-pegtl submodules instead of
# system packages — CentOS 7 has no new-enough asio in its base repos.
# SECURITY stays OFF: it would pull in OpenSSL, and CentOS 7 ships 1.0.2 while Fast DDS
# wants 1.1.1+ (the same version mismatch nats/ sidesteps by disabling TLS in nats.c).
# COMPILE_TOOLS=ON is what produces `fast-discovery-server`, used by --discovery server.
ARG FASTDDS_VERSION=v2.14.3
RUN git clone --depth 1 --branch ${FASTDDS_VERSION} \
      https://github.com/eProsima/Fast-DDS.git /opt/Fast-DDS && \
    cd /opt/Fast-DDS && git submodule update --init --recursive && \
    cmake -S /opt/Fast-DDS -B /opt/Fast-DDS/build \
      -DCMAKE_BUILD_TYPE=Release \
      -DTHIRDPARTY=ON \
      -DSECURITY=OFF \
      -DCOMPILE_EXAMPLES=OFF \
      -DBUILD_DOCUMENTATION=OFF \
      -DCOMPILE_TOOLS=ON && \
    cmake --build /opt/Fast-DDS/build --target install -- -j$(nproc)

# CMake installs into /usr/local/lib (and lib64 on some generators), neither of which is on
# CentOS 7's default loader path — without this, every binary here dies with
# "libfastrtps.so.2: cannot open shared object file".
RUN printf '/usr/local/lib\n/usr/local/lib64\n' > /etc/ld.so.conf.d/fastdds.conf && ldconfig

# --- Build our own benchmark tool -----------------------------------------------------
WORKDIR /opt/dds_bench
COPY tools/dds_bench/ .
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build --target install -- -j$(nproc)

COPY docker/dds-bench/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# No fixed binary: this image runs `dds_bench ...` or `fast-discovery-server ...` depending
# on what the calling script passes (see scripts/bench-*.sh and start-discovery-server.sh).
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
