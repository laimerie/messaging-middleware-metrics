#!/usr/bin/env bash
# install-nats-cli.sh - one-time bootstrap of the official NATS CLI (provides `nats bench`).
#
# Usage:
#   ./scripts/install-nats-cli.sh
set -euo pipefail

if command -v nats >/dev/null 2>&1; then
    echo "nats CLI already installed:"
    nats --version
    exit 0
fi

echo "nats CLI not found on PATH. Attempting install..."

NATS_CLI_VERSION="0.4.0"

install_via_binary() {
    local arch os url tmpdir
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) echo "Unsupported architecture: $(uname -m)" >&2; return 1 ;;
    esac
    os="linux"
    url="https://github.com/nats-io/natscli/releases/download/v${NATS_CLI_VERSION}/nats-${NATS_CLI_VERSION}-${os}-${arch}.zip"
    tmpdir="$(mktemp -d)"
    echo "Downloading $url ..."
    curl -fsSL -o "$tmpdir/nats-cli.zip" "$url" || return 1
    unzip -j "$tmpdir/nats-cli.zip" "*/nats" -d "$tmpdir" || return 1
    chmod +x "$tmpdir/nats"
    if [ -w /usr/local/bin ] 2>/dev/null; then
        mv "$tmpdir/nats" /usr/local/bin/nats
    else
        sudo mv "$tmpdir/nats" /usr/local/bin/nats
    fi
    rm -rf "$tmpdir"
}

if command -v apt-get >/dev/null 2>&1; then
    echo "Trying apt-get..."
    sudo apt-get update -y && sudo apt-get install -y nats-server-cli 2>/dev/null \
        || install_via_binary
elif command -v yum >/dev/null 2>&1; then
    echo "Trying yum (package name varies by repo; falling back to binary release if unavailable)..."
    install_via_binary
else
    install_via_binary
fi

if ! command -v nats >/dev/null 2>&1; then
    cat >&2 <<'EOF'
'nats' is still not on PATH. Options:
  1) Ensure /usr/local/bin is on your PATH and re-run this script.
  2) Manual install: download the Linux release from
     https://github.com/nats-io/natscli/releases and place the `nats` binary
     somewhere on PATH (e.g. /usr/local/bin).
EOF
    exit 1
fi

echo "nats CLI installed:"
nats --version

echo
echo "Environment check:"
docker --version
docker compose version
