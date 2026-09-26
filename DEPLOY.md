# Deployment

Every host under `hosts/` is wired by `flake.nix`: it imports `modules/base.nix` and sets `dome.enable = true`. That turns on comin, discovery, PKI, etcd, Postgres, Knot DNS, Keycloak, the dome.ms backend/web, status, and initrd unlock. Host configs only need disko, boot, and kernel modules.

Peers come from `nodes/<fqdn>.nix` (unordered adjective-animal names). Comin rolls a single git commit to every node. The only other static inputs are the sops secrets and registrar glue for `ns.dome.ms` / `dns.dome.ms`.

All commands run inside `nix develop`.

## 1. Cluster settings (once)

Set in `modules/cluster.nix`:

- `dome.repo.url`: git URL every node pulls from
- `dome.admin.sshKeys`: admin SSH public keys (root login and initrd unlock)

For a private repo, also set `dome.repo.private = true` and add `comin.access_token` to `secrets/cluster.yaml`.

## 2. Admin age key (once per admin)

```bash
age-keygen -o ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt
```

## 3. `.sops.yaml` (repo root)

```yaml
keys:
  - &admin age1...
  - &lurking-bear age1...
creation_rules:
  - path_regex: secrets/cluster\.yaml$
    key_groups:
      - age: [*admin, *lurking-bear]
  - path_regex: hosts/ms/dome/lurking-bear/secrets/[^/]+\.yaml$
    key_groups:
      - age: [*admin, *lurking-bear]
```

Every node's recipient goes into the cluster rule. Each node gets its own host rule. `setup_new_machine.sh` maintains this file.

## 4. Cluster secrets (once)

```bash
openssl req -x509 -nodes -days 3650 \
  -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -subj "/CN=dome.ms cluster CA" -keyout ca.key -out ca.crt
openssl rand -base64 32
sops secrets/cluster.yaml
shred -u ca.key
```

Content of `secrets/cluster.yaml`:

```yaml
dome:
  ca_crt: |
    -----BEGIN CERTIFICATE-----
    ...
  ca_key: |
    -----BEGIN PRIVATE KEY-----
    ...
postgres:
  replicator_password: <openssl rand -base64 32>
  dome_password: <openssl rand -base64 32>
keycloak:
  db_password: <openssl rand -base64 32>
  admin_password: <openssl rand -base64 32>
  client_secret: msdome-secret
```

Each node issues its own TLS certificate from this CA at boot (`dome-pki`). Certificates are valid for 365 days and renew 30 days before expiry. Public HTTPS uses Let's Encrypt DNS-01 against the in-cluster Knot zone.

With `dome.apps.enable` (default), every node also runs Keycloak (Postgres DB `keycloak`), the Django backend (DB `dome`), and the static web frontend — packages come from `dome-ms-backend`.

## 5. DNS

Point the `dome.ms` registrar away from Cloudflare (or any other DNS host) to this cluster:

- NS: `ns.dome.ms` and `dns.dome.ms`
- Glue A/AAAA for those names: every node’s public address (same values as in `nodes/*.nix`)

Until that cutover finishes, public resolvers will not query Knot on the nodes. You can still test locally with `dig @<node-ipv4> dome.ms`.

Each node serves the same zone. Platform names (`dome.ms`, `api`, `id`, `status`, every peer) are A/AAAA to all node addresses. ACME TXT records for the `dome.ms` / `*.dome.ms` DNS-01 cert live under `/dome/dns/` in etcd and are rendered into the zone.

Customer domains outside `dome.ms` use HTTP-01. Challenge files are published to etcd so every node can answer Let’s Encrypt no matter which A record is hit.

## 6. Add a node

`dome.repo.url` in `modules/cluster.nix` must already point at this repo. From `nix develop`, with the stock machine reachable over SSH:

```bash
./setup_new_machine.sh 46.62.154.20
# or: ./setup_new_machine.sh root@46.62.154.20
```

The script SSHes in, discovers the primary NIC (name, MAC, IPv4/IPv6, gateways), draws a free adjective-animal name (for example `lurking-bear.dome.ms`), writes `nodes/<fqdn>.nix`, scaffolds a static ifstate host config, then generates an SSH host key and the age recipient. The first run also creates the admin age key, `.sops.yaml`, and `secrets/cluster.yaml`. Later nodes are added to those creation rules and the cluster file is rekeyed. Host config, node inventory, and encrypted secrets are staged so the flake can see them.

A mode `0600` dump is written to `deploy-log/<fqdn>.log` (gitignored). It contains the host key, admin age identity, and decrypted cluster secrets. Re-running the script reuses `deploy-log/<fqdn>/`.

The script prompts for the stock machine's root password and passes it as `nixos-anywhere --env-password`. Leave it empty to use an SSH key. `ROOT_PASSWORD` or `SSHPASS` skips the prompt. `--prepare-only` stops after keys and sops.

Commit and push the staged files before relying on comin. The root disk is unencrypted, so the machine boots straight into the installed system.

Every node is equal. A peer with an empty etcd data directory joins any healthy member, or after a short random delay initializes a new cluster if none answer. Postgres subscriptions for `keycloak` and `dome` are created automatically. Nginx configs, static site files, and certificates sync over etcd on `dome.sync.interval`.

## 7. Remove a node

1. Delete its `nodes/<fqdn>.nix` and `hosts/...` directory, update `.sops.yaml`, rekey `secrets/cluster.yaml`, and push. Discovery, DNS, and subscriptions drop it on the next reconcile.
2. On any remaining node:

```bash
etcdctl --endpoints https://127.0.0.1:2379 \
  --cacert /var/lib/dome/pki/ca.crt \
  --cert /var/lib/dome/pki/node.crt \
  --key /var/lib/dome/pki/node.key \
  member list
etcdctl ... member remove <id>
```

## 8. Postgres 16 → 18

Nodes that still have `/var/lib/postgresql/16` run `dome-pg-upgrade` once before PostgreSQL 18 starts (`pg_upgrade --link`). Fresh installs use 18 directly.

## Ports

| Port      | Open to                |
| --------- | ---------------------- |
| 22        | everyone               |
| 2222      | everyone (initrd only) |
| 53        | everyone (Knot DNS)    |
| 80, 443   | everyone               |
| 3000      | everyone (web)         |
| 8000      | everyone (backend)     |
| 8080      | everyone (keycloak)    |
| 2379/2380 | peers (etcd)           |
| 5432      | peers (Postgres)       |

## Local VM test

See [tests/README.md](tests/README.md). Short version:

```bash
./tests/run.sh              # automated two-node QEMU check
./tests/run.sh interactive  # REPL with both VMs running
```
