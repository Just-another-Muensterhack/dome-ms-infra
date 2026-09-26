# Local testing

Two QEMU VMs share a VLAN. Peers come from `dome.nodes` (same shape as `nodes/*.nix`):

| Name                   | Address      |
| ---------------------- | ------------ |
| `lurking-bear.dome.ms` | 192.168.67.1 |
| `swift-fox.dome.ms`    | 192.168.67.2 |

Comin and initrd unlock are off (`dome.testing.enable`). Each `./tests/run.sh` invocation generates a fresh random age key, CA, and replicator password.

## Quick run

```bash
./tests/run.sh run
```

This is an impure QEMU cluster check with a new `DOME_TEST_SEED` each time. A pure cached check is:

```bash
nix build .#checks.x86_64-linux.cluster -L
```

Exit 0 means discovery, PKI, etcd (2 members), and Postgres replication all worked.

## Interactive shell into the VMs

Boot the same nodes and drop into the Python test driver REPL (VMs stay up):

```bash
./tests/run.sh interactive
```

Then, in the REPL:

```python
start_all()
lurkingbear.succeed("cat /run/dome/peers")
swiftfox.succeed("etcdctl --endpoints https://127.0.0.1:2379 --cacert /var/lib/dome/pki/ca.crt --cert /var/lib/dome/pki/node.crt --key /var/lib/dome/pki/node.key member list")
lurkingbear.succeed("sudo -u postgres psql -d dome -c '\\dt'")
```

Exit the REPL to shut the VMs down.

## What the automated script asserts

1. `/run/dome/peers` and `/run/dome/self` exist on both nodes
2. Node certs under `/var/lib/dome/pki/`
3. etcd healthy on both; `member list` shows 2 members
4. One logical subscription each way on the `dome` database
5. Insert on lurking-bear appears on swift-fox

## Fixture generation

`./tests/run.sh` always builds new encrypted fixtures (CA + replicator password) unless `DOME_TEST_SEED` is set.

`nix build .#checks.x86_64-linux.cluster` (pure) uses a stable seed, so the fixture derivation is cached.

To write fixtures into `tests/fixtures/` (optional, for inspection):

```bash
./tests/regen-fixtures.sh
```
