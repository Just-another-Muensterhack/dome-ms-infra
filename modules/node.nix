{
  imports = [
    ./initrd-unlock.nix
    ./acme.nix
    ./discovery.nix
    ./firewall.nix
    ./pki.nix
    ./etcd.nix
    ./postgres.nix
    ./pg-apps.nix
    ./keycloak.nix
    ./backend.nix
    ./web.nix
    ./sync.nix
  ];
}
