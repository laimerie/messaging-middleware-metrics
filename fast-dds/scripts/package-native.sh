#!/usr/bin/env bash
# Build a self-contained native package for the real two-host benchmark.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$PROJECT_ROOT/dist"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

docker info >/dev/null 2>&1 || { echo "ERROR: Docker is not running." >&2; exit 1; }
cd "$PROJECT_ROOT"
docker compose build dds-bench
image="fast-dds-bench:local"
stage="$(mktemp -d)"
container="fast-dds-native-pkg-$$"
cleanup() { rm -rf "$stage"; docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
mkdir -p "$stage/scripts"
cp scripts/common.sh scripts/bench-oneway-2host-native.sh "$stage/scripts/"
cat > "$stage/preflight.sh" <<'PREFLIGHT'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "$(uname -m)" == "x86_64" ]] || { echo "ERROR: x86_64 is required." >&2; exit 1; }
for command in awk jq; do command -v "$command" >/dev/null || { echo "ERROR: $command is required." >&2; exit 1; }; done
[[ -x "$root/bin/dds_bench" ]] || { echo "ERROR: package binary is missing." >&2; exit 1; }
echo "Preflight OK: $(uname -m), $(ldd --version 2>/dev/null | head -1)"
PREFLIGHT

docker run -d --name "$container" --entrypoint sleep "$image" 600 >/dev/null
docker cp "$stage/." "$container:/stage/" >/dev/null
docker exec "$container" /bin/sh -c '
set -eu
root=/pkg/fast-dds-bench-native
mkdir -p "$root/bin" "$root/lib" "$root/scripts" "$root/results"
cp /usr/local/bin/dds_bench "$root/bin/"
cp /stage/scripts/*.sh "$root/scripts/"
cp /stage/preflight.sh "$root/"
ldd /usr/local/bin/dds_bench | awk "/=> \/usr\/local\// {print \$3} /^\/usr\/local\// {print \$1}" | while read -r lib; do [ -f "$lib" ] && cp -L "$lib" "$root/lib/"; done
chmod 0755 "$root/bin/dds_bench" "$root/scripts"/*.sh "$root/preflight.sh"
LD_LIBRARY_PATH="$root/lib" "$root/bin/dds_bench" --clock invalid 2>&1 | grep -q "clock must"
tar -czf /pkg.tar.gz -C /pkg fast-dds-bench-native
'

mkdir -p "$OUT_DIR"
tarball="$OUT_DIR/fast-dds-bench-native.tar.gz"
rm -f "$tarball"
docker cp "$container:/pkg.tar.gz" "$tarball" >/dev/null
sha256sum "$tarball" > "$tarball.sha256"
echo "Package: $tarball"
echo "Copy to both hosts, unpack, run ./preflight.sh, then start sub before pub."