#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

system=$(nix eval --impure --raw --expr builtins.currentSystem)
check=".#checks.${system}.cluster"
tap="vde-tap67"

setup_test_network() {
  if ip link show "$tap" >/dev/null 2>&1; then
    echo "error: host interface $tap already exists" >&2
    exit 1
  fi

  sudo -v
  trap cleanup_test_network EXIT INT TERM
  sudo ip tuntap add dev "$tap" mode tap user "$(id -un)"
  sudo ip address add 192.168.67.254/24 dev "$tap"
  sudo ip link set "$tap" up
}

cleanup_test_network() {
  sudo ip link delete "$tap" >/dev/null 2>&1 || true
}

usage() {
  cat <<EOF
Usage: $0 [run|interactive]

  run          build and execute the automated VM test (default)
  interactive  boot both nodes with host SSH access

Fresh random sops fixtures are generated for each invocation.
Set DOME_TEST_SEED to reuse a previous fixture derivation.
EOF
  exit 1
}

cmd=${1:-run}

export DOME_TEST_SEED="${DOME_TEST_SEED:-$(date +%s)-$$}"

case "$cmd" in
  run)
    echo "[*] $check (seed=$DOME_TEST_SEED)"
    nix build --impure "$check" -L
    echo "[✓] cluster check passed"
    ;;
  interactive)
    setup_test_network
    echo "[*] starting interactive driver for $check (seed=$DOME_TEST_SEED)"
    echo "[*] in the REPL, run: start_all()"
    echo "[*] then from another terminal:"
    echo "[*] ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@192.168.67.1"
    echo "[*] ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@192.168.67.2"
    nix run --impure "${check}.driverInteractive"
    ;;
  -h | --help | help)
    usage
    ;;
  *)
    usage
    ;;
esac
