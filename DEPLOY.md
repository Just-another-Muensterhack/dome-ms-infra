# Deployment

Every host under `hosts/` is wired by `flake.nix`: it imports `modules/base.nix` and sets `dome.enable = true`. That turns on comin, discovery, PKI, etcd, Postgres, Keycloak, the dome.ms backend/web, and initrd unlock. Host configs only need disko, boot, and kernel modules.

Peers are discovered at runtime from the A/AAAA records of `nodes.dome.ms`. The only static inputs are the sops secrets and DNS.

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
  - &node1 age1...
creation_rules:
  - path_regex: secrets/cluster\.yaml$
    key_groups:
      - age: [*admin, *node1]
  - path_regex: hosts/ms/dome/node1/secrets/[^/]+\.yaml$
    key_groups:
      - age: [*admin, *node1]
```

Every node's recipient goes into the cluster rule. Each node gets its own host rule.

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

Each node issues its own TLS certificate from this CA at boot (`dome-pki`). Certificates are valid for 365 days and renew 30 days before expiry.

With `dome.apps.enable` (default), every node also runs Keycloak (Postgres DB `keycloak`), the Django backend (DB `dome`), and the static web frontend — packages come from `dome-ms-backend`.

## 5. DNS

For every node:

- `<node>.dome.ms` A/AAAA: its address (SSH, install target)
- `nodes.dome.ms` A/AAAA: one record per node

A node only starts etcd and Postgres once its own address appears in `nodes.dome.ms`.

## 6. Add a node

`dome.repo.url` in `modules/cluster.nix` must already point at this repo. From `nix develop`:

```bash
./setup_new_machine.sh node2.dome.ms [ip]
```

The script copies an existing host directory when `hosts/...` is missing, then generates a 64-character LUKS passphrase, an SSH host key, and the age recipient. The first run also creates the admin age key, `.sops.yaml`, and `secrets/cluster.yaml`. Later nodes are added to those creation rules and the cluster file is rekeyed. Host config and encrypted secrets are staged so the flake can see them.

A mode `0600` dump is written to `deploy-log/<fqdn>.log` (gitignored). It contains the LUKS passphrase, host key, admin age identity, and decrypted cluster secrets. Re-running the script reuses `deploy-log/<fqdn>/`.

The script prompts for the stock machine's root password and passes it as `nixos-anywhere --env-password`. Leave it empty to use an SSH key. `ROOT_PASSWORD` or `SSHPASS` skips the prompt. `--prepare-only` stops after keys and sops.

Commit and push the staged files before relying on comin. After reboot the disk waits for the passphrase from the dump:

```bash
ssh -p 2222 root@node2.dome.ms systemd-tty-ask-password-agent
```

The first node whose address sorts first in `nodes.dome.ms` bootstraps etcd. Every later node joins the running cluster via `etcdctl member add`, and Postgres subscriptions to all peers are created automatically.

## 7. Remove a node

1. Remove its record from `nodes.dome.ms`. Postgres subscriptions to it are dropped within one discovery interval.
2. On any remaining node:

```bash
etcdctl --endpoints https://127.0.0.1:2379 \
  --cacert /var/lib/dome/pki/ca.crt \
  --cert /var/lib/dome/pki/node.crt \
  --key /var/lib/dome/pki/node.key \
  member list
etcdctl ... member remove <id>
```

3. Remove its recipient from `.sops.yaml`, run `sops updatekeys secrets/cluster.yaml`, delete its `hosts/` directory, and push.

## Ports

| Port      | Open to                |
| --------- | ---------------------- |
| 22        | everyone               |
| 2222      | everyone (initrd only) |
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
