#!/usr/bin/env bash
# package-native.sh - build a relocatable tarball for servers that cannot run Docker.
#
#     ./scripts/package-native.sh                       # -> dist/aeron-bench-native-<ver>.tar.gz
#     ./scripts/package-native.sh --out-dir /tmp/pkg
#
# WHY BUILD IN THE CONTAINER AND SHIP THE BINARIES, RATHER THAN BUILD ON THE TARGET
#
# The PTP-synchronised server pair cannot run Docker, and almost certainly cannot have gcc 11
# and CMake 3.31 installed either. But the more important reason is comparability: every nats/
# and fast-dds/ number in this repo was measured under the CentOS 7 / gcc 11 / C++17 client
# runtime, and rebuilding with whatever toolchain those servers happen to have would quietly
# change the client runtime out from under the comparison. Building here and copying out keeps
# the runtime identical and moves only the deployment mechanism.
#
# WHY THE RESULT IS PORTABLE (verified on the image, not assumed)
#
#   * glibc. Built against CentOS 7's glibc 2.17, and glibc is BACKWARD compatible, so the
#     binaries run on any newer host. The notorious "GLIBC_2.34 not found" failure is the
#     opposite direction - new build, old host - which is not what happens here.
#   * libstdc++. tools/aeron_bench/CMakeLists.txt links it statically (-static-libstdc++
#     -static-libgcc), so there is no GLIBCXX version to satisfy at all. Safe here specifically
#     because libaeron and libaeron_driver are pure C - no C++ ABI crosses a .so boundary.
#     aeronmd never needed it: it is a C program.
#   * Aeron's own libraries. Shipped in lib/ and found through RPATH $ORIGIN/../lib, which
#     Aeron already sets on aeronmd and CMakeLists.txt now sets on aeron_bench. No
#     LD_LIBRARY_PATH wrapper is needed, which is why there isn't one.
#
# The package keeps the repo's own directory layout (bin/, lib/, scripts/, results/) so that
# every relative path inside the scripts resolves identically whether it runs from a git
# checkout or from an unpacked tarball.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Git Bash rewrites arguments that look like absolute POSIX paths, and this script passes
# container-internal ones to `docker cp` and `docker exec`. common.sh already excludes /out and
# /dev/shm; this needs /usr, /lib (which covers /lib64), /bin (for --entrypoint /bin/sh) and
# /stage. Omitting any of them silently turns the path into a Windows one, and the symptom is
# "cannot find" a file that is plainly there.
#
# This cannot be MSYS2_ARG_CONV_EXCL='*': `docker cp`'s DESTINATION on this machine is a real
# path and does still need converting. Same trade-off as common.sh's narrower list.
export MSYS2_ARG_CONV_EXCL="/out;/dev/shm;/usr;/lib;/bin;/stage;/pkg"

OUT_DIR="$PROJECT_ROOT/dist"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

assert_docker_running
ensure_image_built

# Only these scripts can run without Docker. bench-rtt-2host.sh and the rest drive
# `docker compose run` and would fail on the target with a confusing error, so they are
# deliberately left out rather than shipped broken.
NATIVE_SCRIPTS=(common.sh common-native.sh bench-oneway-2host.sh)

# Shared libraries to ship. NOT a wildcard copy of everything ldd names: the C runtime
# (libc/libm/libpthread/libdl/librt and the loader itself) MUST come from the target host.
# Shipping CentOS 7's glibc alongside binaries running on a newer kernel is how you get a
# mismatched loader and a segfault before main().
BUNDLED_LIBS="libaeron.so libaeron_driver.so libuuid.so.1"

aeron_version="$(grep -oE 'AERON_VERSION=[0-9.]+' "$PROJECT_ROOT/docker/aeron-bench/Dockerfile" | head -1 | cut -d= -f2)"
: "${aeron_version:=unknown}"
pkg_name="aeron-bench-native-${aeron_version}"

# THE PACKAGE IS ASSEMBLED AND TARRED INSIDE THE CONTAINER, not on this machine, and that is
# not incidental. Two things go wrong otherwise, and only one of them is visible:
#
#   * The executable bit. When this script is run from Windows (as it is during development),
#     the staging directory lives on a filesystem with no POSIX permissions, `chmod +x` is a
#     no-op, and the tarball arrives on the target with non-executable binaries. The symptom is
#     preflight.sh reporting "aeron_bench not found", because its -x test fails on a file that
#     is plainly there. Confirmed the hard way.
#   * Symlinks. libuuid.so.1 is a symlink to libuuid.so.1.3.0, and `docker cp` copies a symlink
#     AS a symlink - which lands in the package as a dangling link to a path that does not
#     exist on the target. Assembling inside the container lets `cp -L` dereference it.
#
# So the host stages only text files, and everything permission- or symlink-sensitive happens
# in Linux.
stage="$(mktemp -d)"
container="aeronbench-pkg-$$"
cleanup() {
    rm -rf "$stage"
    docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$stage/scripts"
cp "$PROJECT_ROOT/lib/aeron-driver.sh" "$stage/aeron-driver.sh"
for s in "${NATIVE_SCRIPTS[@]}"; do
    cp "$PROJECT_ROOT/scripts/$s" "$stage/scripts/$s"
done

# A standalone preflight, so the target can be validated the moment the tarball lands rather
# than discovering a problem partway through a benchmark run.
#
# PKG_ROOT, not SCRIPT_DIR: common.sh assigns SCRIPT_DIR itself when sourced, so reusing that
# name here would repoint it at scripts/ and make the second source path scripts/scripts/.
cat > "$stage/preflight.sh" <<'PREFLIGHT'
#!/usr/bin/env bash
# Verifies this host can actually run the package. Starts nothing, changes nothing, and is
# safe to run any number of times.
set -euo pipefail
PKG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PKG_ROOT/scripts/common.sh"
source "$PKG_ROOT/scripts/common-native.sh"

native_preflight

echo "arch:   $(uname -m)"
echo "glibc:  $(ldd --version 2>/dev/null | head -1)"
echo "cores:  $(nproc)"
echo "shm:    $(df -h /dev/shm 2>/dev/null | awk 'NR==2 {print $2}')"
echo
echo "PTP:"
if command -v pmc >/dev/null 2>&1; then
    pmc -u -b 0 'GET TIME_STATUS_NP' 2>&1 | sed 's/^/  /' \
        || echo "  pmc failed - is ptp4l running?"
else
    echo "  pmc not installed (linuxptp). --clock realtime will still work, but the PTP"
    echo "  offset cannot be recorded into meta.json - and that offset is the error bar on"
    echo "  every one-way number. Install linuxptp, or record it by hand."
fi
echo
echo "Preflight OK."
PREFLIGHT

cat > "$stage/README.txt" <<EOF
aeron-bench native package
==========================
Built:    $(date -Iseconds)
Aeron:    $aeron_version
Runtime:  CentOS 7 / gcc 11 / C++17 - identical to the containerised runs, and to nats/ and
          fast-dds/, so all figures stay comparable
Requires: x86_64, glibc >= 2.17, jq, awk

This exists for hosts that cannot run Docker. Everything else in the project runs through
docker compose; only the two-server one-way latency measurement needs this package.

  1. ./preflight.sh                    on BOTH servers - checks arch, glibc, libraries, PTP
  2. ./scripts/bench-oneway-2host.sh   --role sub on one server, --role pub on the other

Start the SUB side first: it binds the endpoint, and it is where the measurement lands.
Pass the SAME --target-msgs-per-sec and --duration-sec to both sides.

  server B (receiver):  ./scripts/bench-oneway-2host.sh --role sub \\
                          --self-address <B> --peer-address <A> \\
                          --target-msgs-per-sec 10000 --duration-sec 30
  server A (sender):    ./scripts/bench-oneway-2host.sh --role pub \\
                          --self-address <A> --peer-address <B> \\
                          --target-msgs-per-sec 10000 --duration-sec 30

The binaries find their libraries through RPATH \$ORIGIN/../lib. Keep bin/ and lib/ together;
do not move a binary out of bin/ on its own.

The media driver busy-spins THREE cores by default (--driver-idle noop). The scripts stop it
on exit, including on Ctrl-C. If one is ever left behind: pkill -x aeronmd
EOF

echo "Assembling the package inside the image ..."
docker run -d --name "$container" --entrypoint sleep aeron-bench:local 600 >/dev/null
docker cp "$stage/." "$container:/stage/" >/dev/null

docker exec "$container" /bin/sh -c "
set -e
root=/pkg/$pkg_name
mkdir -p \$root/bin \$root/lib \$root/scripts \$root/results

cp /usr/local/bin/aeron_bench /usr/local/bin/aeronmd \$root/bin/

# -L dereferences: these sonames are symlinks, and a symlink in the tarball would dangle on
# the target. Searched rather than hardcoded to one directory because Aeron's install location
# depends on the CMake generator (lib vs lib64).
for lib in $BUNDLED_LIBS; do
    found=0
    for d in /usr/local/lib /usr/local/lib64 /lib64 /usr/lib64; do
        if [ -e \"\$d/\$lib\" ]; then cp -L \"\$d/\$lib\" \"\$root/lib/\$lib\"; found=1; break; fi
    done
    if [ \$found -eq 0 ]; then
        echo \"ERROR: \$lib not found in the image; the package would be incomplete.\" >&2
        exit 1
    fi
done

cp /stage/aeron-driver.sh \$root/lib/aeron-driver.sh
cp /stage/scripts/*.sh \$root/scripts/
cp /stage/preflight.sh /stage/README.txt \$root/

chmod 0755 \$root/bin/* \$root/scripts/*.sh \$root/preflight.sh
chmod 0644 \$root/lib/*.so* \$root/lib/aeron-driver.sh \$root/README.txt

# Confirm the shipped tree is self-contained BEFORE it is shipped: run the binaries out of
# \$root, where RPATH \$ORIGIN/../lib is the only thing that can resolve libaeron.
if \$root/bin/aeron_bench --clock bogus 2>&1 | grep -q 'must be'; then :; else
    echo 'ERROR: the packaged aeron_bench did not run from its package layout.' >&2
    \$root/bin/aeron_bench --clock bogus || true
    exit 1
fi

tar -czf /pkg.tar.gz -C /pkg $pkg_name
"

mkdir -p "$OUT_DIR"
tarball="$OUT_DIR/${pkg_name}.tar.gz"
rm -f "$tarball"
docker cp "$container:/pkg.tar.gz" "$tarball" >/dev/null

sha="$(sha256sum "$tarball" | awk '{print $1}')"
echo "$sha  ${pkg_name}.tar.gz" > "$tarball.sha256"

echo
echo "Package: $tarball"
echo "Size:    $(du -h "$tarball" | awk '{print $1}')"
echo "SHA256:  $sha"
echo
echo "Copy to BOTH servers and unpack:"
echo "  scp ${pkg_name}.tar.gz user@server:"
echo "  tar -xzf ${pkg_name}.tar.gz && cd $pkg_name && ./preflight.sh"
echo
echo "It is a single self-contained file, so any transfer works where scp does not."
echo "Verify with the .sha256 alongside it before running."
