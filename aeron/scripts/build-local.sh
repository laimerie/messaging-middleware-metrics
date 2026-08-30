#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AERON_SOURCE_DIR="${AERON_SOURCE_DIR:-$PROJECT_ROOT/workspace/aeron}"
AERON_BUILD_DIR="${AERON_BUILD_DIR:-$PROJECT_ROOT/workspace/aeron-build}"
AERON_PREFIX="${AERON_PREFIX:-$PROJECT_ROOT/workspace/aeron-install}"
BENCH_BUILD_DIR="${BENCH_BUILD_DIR:-$PROJECT_ROOT/workspace/aeron-bench-build}"
CXX_RUNTIME_DIR="${CXX_RUNTIME_DIR:-}"

if [[ -z "$CXX_RUNTIME_DIR" ]] && command -v "${CXX:-c++}" >/dev/null 2>&1; then
    cxx_runtime="$("${CXX:-c++}" -print-file-name=libstdc++.so.6 2>/dev/null || true)"
    if [[ -f "$cxx_runtime" ]]; then
        CXX_RUNTIME_DIR="$(dirname "$cxx_runtime")"
    fi
fi

reset_moved_build_dir() {
    local build_dir="$1"
    local source_dir="$2"
    local cache_file="$build_dir/CMakeCache.txt"
    local cached_source

    [[ -f "$cache_file" ]] || return 0
    cached_source="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$cache_file" | head -n 1)"
    if [[ -n "$cached_source" && "$cached_source" != "$source_dir" ]]; then
        printf 'INFO: resetting CMake build directory whose source moved:\n' >&2
        printf '      %s\n' "$build_dir" >&2
        printf '      cached source: %s\n' "$cached_source" >&2
        printf '      current source: %s\n' "$source_dir" >&2
        rm -rf "$build_dir"
    fi
}

if ! command -v cmake >/dev/null 2>&1; then
    printf 'ERROR: cmake is required (Aeron needs CMake 3.30 or newer).\n' >&2
    exit 1
fi
cmake_version="$(cmake --version | sed -n '1s/^cmake version //p')"
cmake_major="${cmake_version%%.*}"
cmake_minor="${cmake_version#*.}"
cmake_minor="${cmake_minor%%.*}"
if [[ ! "$cmake_major" =~ ^[0-9]+$ || ! "$cmake_minor" =~ ^[0-9]+$ ]] ||
   (( cmake_major < 3 || (cmake_major == 3 && cmake_minor < 30) )); then
    printf 'ERROR: CMake 3.30 or newer is required; found %s.\n' "${cmake_version:-unknown}" >&2
    printf '       Install a newer CMake and run this script again.\n' >&2
    exit 1
fi

if [[ ! -f "$AERON_SOURCE_DIR/CMakeLists.txt" ]]; then
    AERON_VERSION="${AERON_VERSION:-1.52.2}"
    mkdir -p "$(dirname "$AERON_SOURCE_DIR")"
    if [[ -e "$AERON_SOURCE_DIR" ]]; then
        printf 'ERROR: %s exists but is not an Aeron source tree (CMakeLists.txt is missing).\n' \
            "$AERON_SOURCE_DIR" >&2
        printf '       Move it aside or set AERON_SOURCE_DIR to another directory.\n' >&2
        exit 1
    fi
    git clone --depth 1 --branch "$AERON_VERSION" \
        https://github.com/aeron-io/aeron.git "$AERON_SOURCE_DIR"
elif [[ -z "${AERON_VERSION:-}" ]]; then
    AERON_VERSION="$(git -C "$AERON_SOURCE_DIR" describe --tags --match '[0-9]*' --abbrev=0 2>/dev/null || true)"
    AERON_VERSION="${AERON_VERSION:-1.52.2}"
fi

reset_moved_build_dir "$AERON_BUILD_DIR" "$AERON_SOURCE_DIR"
cmake -S "$AERON_SOURCE_DIR" -B "$AERON_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$AERON_PREFIX" \
    -DBUILD_AERON_DRIVER=ON \
    -DBUILD_AERON_ARCHIVE_API=OFF \
    -DAERON_TESTS=OFF \
    -DAERON_UNIT_TESTS=OFF \
    -DAERON_SYSTEM_TESTS=OFF \
    -DAERON_BUILD_SAMPLES=OFF \
    -DAERON_BUILD_DOCUMENTATION=OFF \
    -DAERON_INSTALL_TARGETS=ON
cmake --build "$AERON_BUILD_DIR" --target install --parallel

reset_moved_build_dir "$BENCH_BUILD_DIR" "$PROJECT_ROOT/tools/aeron_bench"
cmake -S "$PROJECT_ROOT/tools/aeron_bench" -B "$BENCH_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$AERON_PREFIX" \
    -DAERON_PREFIX="$AERON_PREFIX" \
    -DAERON_BENCH_AERON_VERSION="$AERON_VERSION" \
    -DCMAKE_INSTALL_RPATH="$AERON_PREFIX/lib;$AERON_PREFIX/lib64${CXX_RUNTIME_DIR:+;$CXX_RUNTIME_DIR}"
cmake --build "$BENCH_BUILD_DIR" --target install --parallel

printf 'Built Aeron and aeron_bench.\n'
printf '  driver: %s/bin/aeronmd\n' "$AERON_PREFIX"
printf '  bench:  %s/bin/aeron_bench\n' "$AERON_PREFIX"