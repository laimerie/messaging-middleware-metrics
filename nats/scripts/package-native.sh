#!/usr/bin/env bash
# package-native.sh - build the NATS native two-host benchmark package.
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
docker compose build latency-tool
image="nats-latency-tool:local"
docker image inspect "$image" >/dev/null 2>&1 || { echo "ERROR: $image was not found." >&2; exit 1; }

stage="$(mktemp -d)"
container="nats-native-pkg-$$"
cleanup() { rm -rf "$stage"; docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
mkdir -p "$stage/scripts"
cp "$PROJECT_ROOT/scripts/common.sh" "$stage/scripts/"
cp "$PROJECT_ROOT/scripts/bench-oneway-2host-native.sh" "$stage/scripts/"
cp "$PROJECT_ROOT/scripts/bench-leaf-2host-native.sh" "$stage/scripts/"
cp "$PROJECT_ROOT/scripts/summarize-leaf-run.sh" "$stage/scripts/"

cat > "$stage/preflight.sh" <<'PREFLIGHT'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "$(uname -m)" == "x86_64" ]] || { echo "ERROR: x86_64 is required." >&2; exit 1; }
for command in jq curl awk; do command -v "$command" >/dev/null || { echo "ERROR: $command is required." >&2; exit 1; }; done
[[ -x "$root/bin/nats-server" && -x "$root/bin/latency_oneway" ]] || { echo "ERROR: package binaries are incomplete." >&2; exit 1; }
echo "Preflight OK: $(uname -m), $(ldd --version 2>/dev/null | head -1)"
PREFLIGHT

docker run -d --name "$container" --entrypoint sleep "$image" 600 >/dev/null
docker cp "$stage/." "$container:/stage/" >/dev/null
docker exec "$container" /bin/sh -c '
set -eu
root=/pkg/nats-bench-native
mkdir -p "$root/bin" "$root/scripts" "$root/results"
cp /usr/local/bin/nats-server /usr/local/bin/latency_oneway "$root/bin/"
cp /stage/scripts/*.sh "$root/scripts/"
cp /stage/preflight.sh "$root/"
ldd /usr/local/bin/latency_oneway | awk "/=> \/opt\// {print \$3}" | while read -r lib; do cp -L "$lib" "$root/bin/"; done
chmod 0755 "$root/bin"/* "$root/scripts"/*.sh "$root/preflight.sh"
if LD_LIBRARY_PATH="$root/bin" "$root/bin/latency_oneway" --clock invalid 2>&1 | grep -q "clock must"; then :; else exit 1; fi
tar -czf /pkg.tar.gz -C /pkg nats-bench-native
'

mkdir -p "$OUT_DIR"
tarball="$OUT_DIR/nats-bench-native.tar.gz"
rm -f "$tarball"
docker cp "$container:/pkg.tar.gz" "$tarball" >/dev/null
sha256sum "$tarball" > "$tarball.sha256"
echo "Package: $tarball"
echo "Copy to both hosts, unpack, run ./preflight.sh, then start sub before pub."