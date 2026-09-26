#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: gen-fixtures.sh DIR}
mkdir -p "$out"
cd "$out"

age-keygen -o age-key.txt 2>/dev/null
AGE_PUB=$(age-keygen -y age-key.txt)
export SOPS_AGE_KEY_FILE="$PWD/age-key.txt"

openssl req -x509 -nodes -days 3650 \
  -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -subj "/CN=dome.ms test CA" -keyout ca.key -out ca.crt 2>/dev/null

python3 - <<'PY'
import secrets
from pathlib import Path

ca_crt = Path("ca.crt").read_text().rstrip("\n")
ca_key = Path("ca.key").read_text().rstrip("\n")

def indent(s):
    return "\n".join(("    " + line) if line else "" for line in s.splitlines())

keycloak_admin = secrets.token_urlsafe(32)
keycloak_client = secrets.token_urlsafe(32)
keycloak_db = secrets.token_urlsafe(32)
dome_db = secrets.token_urlsafe(32)
replicator = secrets.token_urlsafe(32)

Path("cluster.yaml").write_text(f"""dome:
  ca_crt: |
{indent(ca_crt)}
  ca_key: |
{indent(ca_key)}
keycloak:
  admin_password: {keycloak_admin}
  client_secret: {keycloak_client}
  db_password: {keycloak_db}
postgres:
  dome_password: {dome_db}
  replicator_password: {replicator}
""")
Path("host-secrets.yaml").write_text('placeholder: "true"\n')
PY

cat > .sops.yaml <<SOPS
keys:
  - &test ${AGE_PUB}
creation_rules:
  - path_regex: cluster\.yaml$
    key_groups:
      - age:
          - *test
  - path_regex: host-secrets\.yaml$
    key_groups:
      - age:
          - *test
SOPS

sops -e -i cluster.yaml
sops -e -i host-secrets.yaml
rm -f ca.key ca.crt
chmod 600 age-key.txt
