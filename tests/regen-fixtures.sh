#!/usr/bin/env bash
set -euo pipefail

dir=$(cd "$(dirname "$0")/fixtures" && pwd)

nix shell nixpkgs#age nixpkgs#sops nixpkgs#openssl nixpkgs#python3 -c \
  bash "$(cd "$(dirname "$0")" && pwd)/gen-fixtures.sh" "$dir"

echo "[✓] wrote $dir/{age-key.txt,cluster.yaml,host-secrets.yaml,.sops.yaml}"
echo "[*] recipient: $(nix shell nixpkgs#age -c age-keygen -y "$dir/age-key.txt")"
