{
  pkgs,
  inputs,
  seed ? "0",
}:
let
  fixtures = import ./mk-fixtures.nix { inherit pkgs seed; };
  adminSshKeys = import ../admin-keys.nix {
    inherit (pkgs) lib;
    inherit inputs;
  };

  mkNode =
    {
      fqdn,
      address,
    }:
    {
      _module.args = {
        inherit inputs fqdn;
        hostPath = fixtures;
      };

      imports = [
        inputs.comin.nixosModules.comin
        inputs.sops-nix.nixosModules.sops
        ../modules/base.nix
      ];

      dome = {
        enable = true;
        testing.enable = true;
        apps.publicHost = address;
        repo.url = "https://example.com/dome.ms.git";
        admin.sshKeys = adminSshKeys;
        sops.clusterFile = fixtures + "/cluster.yaml";
        discovery.name = "nodes.dome.ms";
      };

      sops = {
        defaultSopsFile = pkgs.lib.mkForce (fixtures + "/host-secrets.yaml");
        age.keyFile = "/etc/dome-test-age-key";
      };

      environment.etc."dome-test-age-key" = {
        source = fixtures + "/age-key.txt";
        mode = "0400";
      };

      networking = {
        hostName = pkgs.lib.head (pkgs.lib.splitString "." fqdn);
        domain = "dome.ms";
        useDHCP = false;
        interfaces.eth1.ipv4.addresses = [
          {
            inherit address;
            prefixLength = 24;
          }
        ];
        extraHosts = ''
          192.168.67.1 node1.dome.ms
          192.168.67.2 node2.dome.ms
          192.168.67.1 nodes.dome.ms
          192.168.67.2 nodes.dome.ms
        '';
      };

      virtualisation.vlans = [ 67 ];
      virtualisation.memorySize = 3072;
      system.stateVersion = "26.05";
    };
in
pkgs.testers.nixosTest {
  name = "dome-cluster";

  nodes = {
    node1 = mkNode {
      fqdn = "node1.dome.ms";
      address = "192.168.67.1";
    };
    node2 = mkNode {
      fqdn = "node2.dome.ms";
      address = "192.168.67.2";
    };
  };

  testScript = ''
    start_all()

    for node in [node1, node2]:
        node.wait_for_unit("multi-user.target")
        node.wait_for_file("/run/dome/peers")
        node.wait_for_file("/run/dome/self")
        node.wait_for_file("/var/lib/dome/pki/node.crt")

    node1.wait_for_unit("etcd.service")
    node2.wait_until_succeeds("systemctl is-active etcd.service", timeout=180)

    etcd = (
        "etcdctl --endpoints https://127.0.0.1:2379 "
        "--cacert /var/lib/dome/pki/ca.crt "
        "--cert /var/lib/dome/pki/node.crt "
        "--key /var/lib/dome/pki/node.key "
    )

    node1.wait_until_succeeds(etcd + "endpoint health")
    node2.wait_until_succeeds(etcd + "endpoint health")
    node1.wait_until_succeeds(etcd + "member list | grep -c node | grep 2")

    node1.wait_for_unit("postgresql.service")
    node2.wait_for_unit("postgresql.service")

    node1.succeed(
        "sudo -u postgres psql -c \"CREATE TABLE IF NOT EXISTS dome_probe(id int primary key, note text);\""
    )
    node2.succeed(
        "sudo -u postgres psql -c \"CREATE TABLE IF NOT EXISTS dome_probe(id int primary key, note text);\""
    )

    node1.succeed("systemctl start dome-pg-reconcile.service")
    node2.succeed("systemctl start dome-pg-reconcile.service")

    node1.wait_until_succeeds(
        "sudo -u postgres psql -tAc \"SELECT count(*) FROM pg_subscription WHERE subname LIKE 'sub_%'\" | grep -q 1"
    )
    node2.wait_until_succeeds(
        "sudo -u postgres psql -tAc \"SELECT count(*) FROM pg_subscription WHERE subname LIKE 'sub_%'\" | grep -q 1"
    )

    # Refresh so subscriptions pick up tables created after the first reconcile.
    node1.succeed("systemctl start dome-pg-reconcile.service")
    node2.succeed("systemctl start dome-pg-reconcile.service")

    node1.succeed(
        "sudo -u postgres psql -c \"INSERT INTO dome_probe VALUES (1, 'from-node1') ON CONFLICT (id) DO UPDATE SET note = EXCLUDED.note;\""
    )
    node2.wait_until_succeeds(
        "sudo -u postgres psql -tAc \"SELECT note FROM dome_probe WHERE id = 1\" | grep from-node1",
        timeout=60,
    )

    peers = node1.succeed("cat /run/dome/peers").strip().splitlines()
    assert "192.168.67.1" in peers
    assert "192.168.67.2" in peers
    resolved = node1.succeed("getent ahosts nodes.dome.ms | awk '{print $1}' | sort -u")
    assert "192.168.67.1" in resolved
    assert "192.168.67.2" in resolved
  '';
}
