#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [--prepare-only] <fqdn> [ssh-target]"
  echo
  echo "  fqdn         flake target, for example node1.dome.ms"
  echo "  ssh-target   install address (defaults to fqdn)"
  echo
  echo "Generates a 64-character LUKS passphrase, an SSH host key, and sops"
  echo "recipients. Writes deploy-log/<fqdn>.log (mode 0600, gitignored)."
  echo "Re-runs reuse deploy-log/<fqdn>/ so the disk key and host key stay put."
  echo
  echo "  --prepare-only   write keys and secrets, do not install"
  echo "  ROOT_PASSWORD    current root password of the stock machine"
  echo "  SSHPASS          same password, passed to nixos-anywhere --env-password"
  echo
  echo "Run inside nix develop so age-keygen, ssh-to-age, sops, and nixos-anywhere are on PATH."
  exit 1
}

PREPARE_ONLY=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --prepare-only) PREPARE_ONLY=1 ;;
    -h | --help) usage ;;
    *) ARGS+=("$arg") ;;
  esac
done

if [[ ${#ARGS[@]} -lt 1 || ${#ARGS[@]} -gt 2 ]]; then
  usage
fi

FQDN="${ARGS[0]}"
SSH_TARGET="${ARGS[1]:-$FQDN}"

if [[ ! "$FQDN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ || "$FQDN" != *.* || "$FQDN" == *..* ]]; then
  echo "Invalid fqdn: $FQDN" >&2
  exit 1
fi

if [[ "$SSH_TARGET" == *" "* || "$SSH_TARGET" == *$'\n'* || -z "$SSH_TARGET" ]]; then
  echo "Invalid ssh target" >&2
  exit 1
fi

if [[ "$SSH_TARGET" == *@* ]]; then
  SSH_CONN="$SSH_TARGET"
  SSH_HOST="${SSH_TARGET#*@}"
else
  SSH_CONN="root@$SSH_TARGET"
  SSH_HOST="$SSH_TARGET"
fi

cd "$(dirname "$(readlink -f "$0")")"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing '$1'. Run this script inside nix develop." >&2
    exit 1
  fi
}

need age-keygen
need ssh-to-age
need sops
need openssl
need ssh-keygen
need python3
if [[ "$PREPARE_ONLY" -eq 0 ]]; then
  need nixos-anywhere
fi

fqdn_to_host_path() {
  local fqdn=$1
  local IFS=.
  local -a parts
  local path="hosts"
  local i
  read -ra parts <<< "$fqdn"
  for ((i = ${#parts[@]} - 1; i >= 0; i--)); do
    path+="/${parts[i]}"
  done
  printf '%s\n' "$path"
}

HOST_PATH="$(fqdn_to_host_path "$FQDN")"
HOST_SECRET_REGEX="${HOST_PATH}/secrets/[^/]+\\.yaml\$"
HOST_SECRET="$HOST_PATH/secrets/secrets.yaml"

scaffold_host() {
  if [[ -f "$HOST_PATH/configuration.nix" ]]; then
    return
  fi
  local template
  template="$(find hosts -mindepth 2 -name configuration.nix -printf '%h\n' 2>/dev/null | head -n 1 || true)"
  install -d "$HOST_PATH"
  if [[ -n "$template" && -f "$template/configuration.nix" && -f "$template/disko.nix" ]]; then
    cp "$template/configuration.nix" "$template/disko.nix" "$HOST_PATH/"
    echo "[+] Created $HOST_PATH from $template"
  else
    echo "No host template under hosts/ to copy for $FQDN" >&2
    exit 1
  fi
}

scaffold_host

STATE="deploy-log/$FQDN"
LOG="deploy-log/${FQDN}.log"
install -d -m 700 deploy-log "$STATE"

if [[ ! -f "$STATE/ssh_host_ed25519_key" ]]; then
  ssh-keygen -q -o -a 100 -N "" -t ed25519 -C "root@$FQDN" -f "$STATE/ssh_host_ed25519_key"
  echo "[+] Generated SSH host key for $FQDN"
else
  echo "[*] Reusing SSH host key in $STATE"
fi
chmod 600 "$STATE/ssh_host_ed25519_key"

if [[ ! -f "$STATE/luks.key" ]]; then
  openssl rand -base64 48 | tr -d '\n' > "$STATE/luks.key"
  echo "[+] Generated 64-character LUKS passphrase"
else
  echo "[*] Reusing LUKS passphrase in $STATE/luks.key"
fi
chmod 600 "$STATE/luks.key"

LUKS_LEN="$(wc -c < "$STATE/luks.key" | tr -d ' ')"
if [[ "$LUKS_LEN" -ne 64 ]]; then
  echo "LUKS passphrase in $STATE/luks.key is $LUKS_LEN chars, expected 64" >&2
  exit 1
fi

AGE_RECIPIENT="$(ssh-to-age < "$STATE/ssh_host_ed25519_key.pub")"
printf '%s\n' "$AGE_RECIPIENT" > "$STATE/age.pub"
echo "[*] Age recipient: $AGE_RECIPIENT"

ADMIN_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE="$ADMIN_KEY_FILE"
ADMIN_KEY_CREATED=0
if [[ ! -s "$ADMIN_KEY_FILE" ]]; then
  install -d -m 700 "$(dirname "$ADMIN_KEY_FILE")"
  age-keygen -o "$ADMIN_KEY_FILE" >/dev/null 2>&1
  ADMIN_KEY_CREATED=1
  echo "[+] Created admin age key at $ADMIN_KEY_FILE"
else
  echo "[*] Using admin age key at $ADMIN_KEY_FILE"
fi
chmod 600 "$ADMIN_KEY_FILE"

mapfile -t ADMIN_PUBS < <(age-keygen -y "$ADMIN_KEY_FILE")
if [[ ${#ADMIN_PUBS[@]} -eq 0 ]]; then
  echo "No age public keys in $ADMIN_KEY_FILE" >&2
  exit 1
fi
printf '%s\n' "${ADMIN_PUBS[@]}" > "$STATE/admin.pub"
chmod 600 "$STATE/admin.pub"

export FQDN AGE_RECIPIENT HOST_SECRET_REGEX
export ADMIN_PUBS_FILE="$STATE/admin.pub"
python3 - << 'PY'
import os
from pathlib import Path

path = Path(".sops.yaml")
marker = "# Managed by setup_new_machine.sh."
text = path.read_text() if path.exists() else ""
if text.strip() and not text.startswith(marker):
    raise SystemExit(".sops.yaml exists and is not managed by setup_new_machine.sh")

admins = []
hosts = []
mode = None
current = None
for line in text.splitlines():
    if line == "keys:":
        continue
    if line == "creation_rules:":
        break
    if line == "  admins:":
        mode = "admins"
        current = None
        continue
    if line == "  hosts:":
        mode = "hosts"
        current = None
        continue
    if mode == "admins" and line.startswith("    - "):
        admins.append(line[6:].strip())
    elif mode == "hosts" and line.startswith("    - fqdn: "):
        current = {"fqdn": line.split(": ", 1)[1].strip()}
        hosts.append(current)
    elif mode == "hosts" and current is not None and line.startswith("      age: "):
        current["age"] = line.split(": ", 1)[1].strip()
    elif mode == "hosts" and current is not None and line.startswith("      path_regex: "):
        value = line.split(": ", 1)[1].strip()
        if len(value) >= 2 and value[0] == "'" and value[-1] == "'":
            value = value[1:-1].replace("''", "'")
        current["path_regex"] = value

new_admins = Path(os.environ["ADMIN_PUBS_FILE"]).read_text().splitlines()
for admin in new_admins:
    if admin and admin not in admins:
        admins.append(admin)
if not admins:
    raise SystemExit("no admin age recipients")

fqdn = os.environ["FQDN"]
recipient = os.environ["AGE_RECIPIENT"]
secret_regex = os.environ["HOST_SECRET_REGEX"]
replaced = False
for host in hosts:
    if host.get("fqdn") == fqdn:
        host["age"] = recipient
        host["path_regex"] = secret_regex
        replaced = True
if not replaced:
    hosts.append({"fqdn": fqdn, "age": recipient, "path_regex": secret_regex})

def quote(value):
    return "'" + value.replace("'", "''") + "'"

def unique(values):
    seen = set()
    out = []
    for value in values:
        if value not in seen:
            seen.add(value)
            out.append(value)
    return out

lines = [marker, "keys:", "  admins:"]
for admin in admins:
    lines.append(f"    - {admin}")
lines.append("  hosts:")
for host in hosts:
    lines.append(f"    - fqdn: {host['fqdn']}")
    lines.append(f"      age: {host['age']}")
    lines.append(f"      path_regex: {quote(host['path_regex'])}")
lines.append("creation_rules:")
lines.append(r"  - path_regex: 'secrets/cluster\.yaml$'")
lines.append("    key_groups:")
lines.append("      - age:")
for recipient_key in unique(admins + [host["age"] for host in hosts]):
    lines.append(f"        - {recipient_key}")
for host in hosts:
    lines.append(f"  - path_regex: {quote(host['path_regex'])}")
    lines.append("    key_groups:")
    lines.append("      - age:")
    for recipient_key in unique(admins + [host["age"]]):
        lines.append(f"        - {recipient_key}")
path.write_text("\n".join(lines) + "\n")
PY
echo "[+] Updated .sops.yaml"

CLUSTER_ACTION="updatekeys"
if [[ ! -f secrets/cluster.yaml ]]; then
  work="$(mktemp -d)"
  openssl req -x509 -nodes -days 3650 \
    -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -subj "/CN=dome.ms cluster CA" \
    -keyout "$work/ca.key" -out "$work/ca.crt" 2>/dev/null
  install -d secrets
  {
    echo "dome:"
    echo "  ca_crt: |"
    sed 's/^/    /' "$work/ca.crt"
    echo "  ca_key: |"
    sed 's/^/    /' "$work/ca.key"
    echo "postgres:"
    echo "  replicator_password: \"$(openssl rand -base64 32 | tr -d '\n')\""
    echo "  dome_password: \"$(openssl rand -base64 32 | tr -d '\n')\""
    echo "keycloak:"
    echo "  db_password: \"$(openssl rand -base64 32 | tr -d '\n')\""
    echo "  admin_password: \"$(openssl rand -base64 32 | tr -d '\n')\""
    echo "  client_secret: \"$(openssl rand -base64 32 | tr -d '\n')\""
  } > secrets/cluster.yaml
  rm -rf "$work"
  sops -e -i secrets/cluster.yaml
  CLUSTER_ACTION="created"
  echo "[+] Created secrets/cluster.yaml"
else
  sops updatekeys -y secrets/cluster.yaml
  echo "[+] Rekeyed secrets/cluster.yaml"
fi

install -d "$HOST_PATH/secrets"
HOST_SECRET_ACTION="updatekeys"
if [[ ! -f "$HOST_SECRET" ]]; then
  printf 'placeholder: "true"\n' > "$HOST_SECRET"
  sops -e -i "$HOST_SECRET"
  HOST_SECRET_ACTION="created"
  echo "[+] Created $HOST_SECRET"
else
  sops updatekeys -y "$HOST_SECRET"
  echo "[+] Rekeyed $HOST_SECRET"
fi

HOST_AGE_ID="$(mktemp)"
cleanup() {
  rm -rf "${EXTRA_DIR:-}" "${HOST_AGE_ID:-}"
}
trap cleanup EXIT
ssh-to-age -private-key -i "$STATE/ssh_host_ed25519_key" > "$HOST_AGE_ID"
chmod 600 "$HOST_AGE_ID"
SOPS_AGE_KEY_FILE="$HOST_AGE_ID" sops -d secrets/cluster.yaml >/dev/null
SOPS_AGE_KEY_FILE="$HOST_AGE_ID" sops -d "$HOST_SECRET" >/dev/null
echo "[+] Host age key can decrypt cluster and host secrets"

umask 077
{
  echo "fqdn: $FQDN"
  echo "ssh_target: $SSH_CONN"
  echo "created: $(date -Is)"
  echo "host_path: $HOST_PATH"
  echo
  echo "luks_passphrase: $(cat "$STATE/luks.key")"
  echo "luks_chars: $LUKS_LEN"
  echo
  echo "age_recipient: $AGE_RECIPIENT"
  echo
  echo "ssh_host_ed25519_pub:"
  cat "$STATE/ssh_host_ed25519_key.pub"
  echo
  echo "ssh_host_ed25519_key:"
  cat "$STATE/ssh_host_ed25519_key"
  echo
  echo "admin_age_created: $ADMIN_KEY_CREATED"
  echo "admin_age_identity_file: $ADMIN_KEY_FILE"
  echo "admin_age_public:"
  printf '%s\n' "${ADMIN_PUBS[@]}"
  echo
  echo "admin_age_identity:"
  cat "$ADMIN_KEY_FILE"
  echo
  echo "sops_cluster: $CLUSTER_ACTION secrets/cluster.yaml"
  echo "sops_host: $HOST_SECRET_ACTION $HOST_SECRET"
  echo
  echo "cluster_secrets:"
  sops -d secrets/cluster.yaml
  echo
  echo "unlock_after_reboot:"
  echo "  ssh -p 2222 root@$SSH_HOST systemd-tty-ask-password-agent"
  echo "  luks_passphrase is at the top of this file"
} > "$LOG"
chmod 600 "$LOG"
echo "[+] Wrote $LOG"

git add -- .sops.yaml secrets/cluster.yaml "$HOST_PATH/configuration.nix" "$HOST_PATH/disko.nix" "$HOST_SECRET"
echo "[+] Staged sops files and host config so the flake can see them"

if [[ "$PREPARE_ONLY" -eq 1 ]]; then
  echo "[✓] Prepared $FQDN"
  echo "[✓] Dump: $LOG"
  exit 0
fi

BLOCKERS=()
if grep -q 'repo.url = lib.mkDefault "";' modules/cluster.nix; then
  BLOCKERS+=("Set dome.repo.url in modules/cluster.nix to the git URL comin pulls.")
fi
if [[ ${#BLOCKERS[@]} -gt 0 ]]; then
  echo "Install is blocked:" >&2
  printf '  - %s\n' "${BLOCKERS[@]}" >&2
  echo "Dump: $LOG" >&2
  exit 1
fi

if [[ -z "${SSHPASS:-}" && -n "${ROOT_PASSWORD:-}" ]]; then
  export SSHPASS="$ROOT_PASSWORD"
fi
if [[ -z "${SSHPASS:-}" && -t 0 ]]; then
  read -rsp "Root password for $SSH_CONN (empty to use an SSH key): " SSHPASS
  echo
  if [[ -n "$SSHPASS" ]]; then
    export SSHPASS
  fi
fi

EXTRA_DIR="$(mktemp -d)"
install -d -m 755 "$EXTRA_DIR/etc/ssh"
install -m 600 "$STATE/ssh_host_ed25519_key" "$EXTRA_DIR/etc/ssh/ssh_host_ed25519_key"
install -m 644 "$STATE/ssh_host_ed25519_key.pub" "$EXTRA_DIR/etc/ssh/ssh_host_ed25519_key.pub"

NA_ARGS=(
  --extra-files "$EXTRA_DIR"
  --disk-encryption-keys /tmp/storage.key "$STATE/luks.key"
  --flake ".#$FQDN"
  -L
)
if [[ -n "${SSHPASS:-}" ]]; then
  NA_ARGS+=(--env-password)
fi

echo "[*] Installing NixOS on $SSH_CONN..."
set +e
nixos-anywhere "${NA_ARGS[@]}" "$SSH_CONN" 2>&1 | tee -a "$LOG"
INSTALL_RC=${PIPESTATUS[0]}
set -e
if [[ "$INSTALL_RC" -ne 0 ]]; then
  echo "install_status: failed ($INSTALL_RC)" >> "$LOG"
  echo "Install failed. Dump: $LOG" >&2
  exit "$INSTALL_RC"
fi
echo "install_status: ok" >> "$LOG"

PUB_BODY="$(cut -d ' ' -f 1-2 "$STATE/ssh_host_ed25519_key.pub")"
install -d -m 700 "${HOME}/.ssh"
touch "${HOME}/.ssh/known_hosts"
while read -r known_host; do
  ssh-keygen -R "$known_host" >/dev/null 2>&1 || true
done << EOF
$SSH_HOST
$FQDN
[$SSH_HOST]:2222
[$FQDN]:2222
EOF
{
  echo "$SSH_HOST $PUB_BODY"
  echo "[$SSH_HOST]:2222 $PUB_BODY"
  if [[ "$SSH_HOST" != "$FQDN" ]]; then
    echo "$FQDN $PUB_BODY"
    echo "[$FQDN]:2222 $PUB_BODY"
  fi
} >> "${HOME}/.ssh/known_hosts"

echo "[✓] Installed $FQDN"
echo "[*] Unlock after reboot: ssh -p 2222 root@$SSH_HOST systemd-tty-ask-password-agent"
echo "[✓] Dump: $LOG"
echo "[*] Commit and push the staged sops and host files so comin keeps this generation."
