# latency-tool: one-way (publisher -> subscriber) latency benchmark for NATS Core, and
# (TODO.md #3) a general "host client" image for the cross-host container tests - it
# bundles both our own latency_oneway binary and the official nats CLI, and can inject
# artificial network latency via tc netem, so the same image drives both same-host
# (bench-latency-oneway.ps1) and cross-host (bench-crosshost.ps1) scenarios.
#
# Built to match the production runtime (CentOS 7 / gcc 11 / C++17) so the measurement
# client's own overhead doesn't get confused with NATS Core's actual latency
# (see TODO.md #4 for why this replaced an earlier Python-based plan).
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
    yum install -y devtoolset-11-gcc devtoolset-11-gcc-c++ devtoolset-11-make git curl make \
      unzip iproute && \
    yum clean all
# unzip: the nats CLI release below ships as .zip (Windows and Linux both).
# iproute: provides `tc`, used by entrypoint.sh for netem delay injection.

ENV PATH=/opt/rh/devtoolset-11/root/usr/bin:$PATH \
    LD_LIBRARY_PATH=/opt/rh/devtoolset-11/root/usr/lib64:$LD_LIBRARY_PATH

# --- CMake (CentOS 7's yum cmake is 2.8, far too old) ---------------------------------
ARG CMAKE_VERSION=3.27.9
RUN curl -fsSL -o /tmp/cmake.tar.gz \
      https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz && \
    tar -xzf /tmp/cmake.tar.gz -C /opt && \
    ln -s /opt/cmake-${CMAKE_VERSION}-linux-x86_64/bin/cmake /usr/local/bin/cmake && \
    ln -s /opt/cmake-${CMAKE_VERSION}-linux-x86_64/bin/ctest /usr/local/bin/ctest && \
    rm /tmp/cmake.tar.gz

# --- Build nats.c (NATS Core only: Streaming and TLS both disabled) ------------------
# TLS is off because this project's NATS server has no TLS configured, and CentOS 7's
# stock OpenSSL (1.0.2) is older than what nats.c requires (1.1.1+) — disabling TLS
# avoids that whole version mismatch.
ARG NATS_C_VERSION=v3.13.0
RUN git clone --branch ${NATS_C_VERSION} --depth 1 https://github.com/nats-io/nats.c.git /opt/nats.c && \
    cmake -S /opt/nats.c -B /opt/nats.c/build \
      -DCMAKE_BUILD_TYPE=Release \
      -DNATS_BUILD_STREAMING=OFF \
      -DNATS_BUILD_WITH_TLS=OFF && \
    cmake --build /opt/nats.c/build --target install -- -j$(nproc)

# --- Build our own one-way latency tool -----------------------------------------------
WORKDIR /opt/latency_oneway
COPY tools/latency_oneway/ .
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build --target install -- -j$(nproc)

# --- Native package server -------------------------------------------------------------
# The native two-host benchmark runs the single NATS server on the publisher host. Use
# the official statically linked Linux binary so the package does not depend on Docker or
# the target host's Go toolchain.
ARG NATS_SERVER_VERSION=2.11.17
RUN curl -fsSL -o /tmp/nats-server.tar.gz \
      https://github.com/nats-io/nats-server/releases/download/v${NATS_SERVER_VERSION}/nats-server-v${NATS_SERVER_VERSION}-linux-amd64.tar.gz && \
    tar -xzf /tmp/nats-server.tar.gz -C /tmp && \
    install -m 0755 /tmp/nats-server-v${NATS_SERVER_VERSION}-linux-amd64/nats-server /usr/local/bin/nats-server && \
    rm -rf /tmp/nats-server.tar.gz /tmp/nats-server-v${NATS_SERVER_VERSION}-linux-amd64

# --- nats CLI (same version as the Windows-side install, TODO.md #1/#2/#5/#6 scripts) --
ARG NATS_CLI_VERSION=0.4.0
RUN curl -fsSL -o /tmp/nats-cli.zip \
      https://github.com/nats-io/natscli/releases/download/v${NATS_CLI_VERSION}/nats-${NATS_CLI_VERSION}-linux-amd64.zip && \
    unzip -j /tmp/nats-cli.zip "*/nats" -d /usr/local/bin && \
    chmod +x /usr/local/bin/nats && \
    rm /tmp/nats-cli.zip

COPY docker/latency-tool/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# No fixed binary here (unlike the old `["/usr/local/bin/latency_oneway"]`): this image
# now runs either `latency_oneway ...` or `nats bench ...` depending on the command
# passed by the calling script (see bench-latency-oneway.ps1 / bench-crosshost.ps1).
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
