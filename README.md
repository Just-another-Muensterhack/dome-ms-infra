# dome.ms infrastructure

NixOS flake for the [dome.ms](https://dome.ms) cluster. Every host under `hosts/` imports the same module set. Peers are listed in `nodes/<fqdn>.nix`, and [comin](https://github.com/nlewo/comin) rolls one git commit out to all of them.

## Live

- [dome.ms](https://dome.ms) — site and dashboard
- [status.dome.ms](https://status.dome.ms) — nodes, services, and certificates
- [api.dome.ms](https://api.dome.ms) — API
- [id.dome.ms](https://id.dome.ms) — login
- [grafana.dome.ms](https://grafana.dome.ms) — metrics

Authoritative DNS is `ns.dome.ms` and `dns.dome.ms`.

Application code: [dome-ms-backend](https://github.com/Just-another-Muensterhack/dome-ms-backend).

## On each node

Knot DNS, etcd, Postgres, Keycloak, the Django API, the static web frontend, nginx with a WAF, Let’s Encrypt, Gatus, and Grafana. Public HTTPS for `dome.ms` uses DNS-01 against the in-cluster zone.

## Operate

All commands run inside `nix develop`.

- [DEPLOY.md](DEPLOY.md) — cluster secrets, DNS cutover, adding and removing a node
- [tests/README.md](tests/README.md) — two-node QEMU check

```bash
./tests/run.sh
```
