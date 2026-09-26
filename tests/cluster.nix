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
      ipv6,
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
        nodes = {
          "lurking-bear.dome.ms" = {
            ipv4 = "192.168.67.1";
            ipv6 = "fd67::1";
          };
          "swift-fox.dome.ms" = {
            ipv4 = "192.168.67.2";
            ipv6 = "fd67::2";
          };
        };
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
        interfaces.eth1.ipv6.addresses = [
          {
            address = ipv6;
            prefixLength = 64;
          }
        ];
      };

      virtualisation.vlans = [ 67 ];
      virtualisation.memorySize = 3072;
      system.stateVersion = "26.05";
    };
in
pkgs.testers.nixosTest {
  name = "dome-cluster";

  nodes = {
    lurkingbear = mkNode {
      fqdn = "lurking-bear.dome.ms";
      address = "192.168.67.1";
      ipv6 = "fd67::1";
    };
    swiftfox = mkNode {
      fqdn = "swift-fox.dome.ms";
      address = "192.168.67.2";
      ipv6 = "fd67::2";
    };
  };

  testScript = ''
    start_all()

    for node in [lurkingbear, swiftfox]:
        node.wait_for_unit("multi-user.target")
        node.wait_for_file("/run/dome/peers")
        node.wait_for_file("/run/dome/self")
        node.wait_for_file("/var/lib/dome/pki/node.crt")

    lurkingbear.wait_for_unit("etcd.service")
    swiftfox.wait_until_succeeds("systemctl is-active etcd.service", timeout=180)

    etcd = (
        "etcdctl --endpoints https://127.0.0.1:2379 "
        "--cacert /var/lib/dome/pki/ca.crt "
        "--cert /var/lib/dome/pki/node.crt "
        "--key /var/lib/dome/pki/node.key "
    )

    lurkingbear.wait_until_succeeds(etcd + "endpoint health")
    swiftfox.wait_until_succeeds(etcd + "endpoint health")
    lurkingbear.wait_until_succeeds(etcd + "member list | grep -c dome.ms | grep 2")

    lurkingbear.wait_for_unit("postgresql.service")
    swiftfox.wait_for_unit("postgresql.service")

    for db in ["dome", "keycloak"]:
        lurkingbear.succeed(
            f"sudo -u postgres psql -d {db} -c \"CREATE TABLE IF NOT EXISTS dome_probe(id int primary key, note text);\""
        )
        swiftfox.succeed(
            f"sudo -u postgres psql -d {db} -c \"CREATE TABLE IF NOT EXISTS dome_probe(id int primary key, note text);\""
        )

    lurkingbear.succeed("systemctl start dome-pg-reconcile.service")
    swiftfox.succeed("systemctl start dome-pg-reconcile.service")

    lurkingbear.wait_until_succeeds(
        "sudo -u postgres psql -d dome -tAc \"SELECT count(*) FROM pg_subscription WHERE subname LIKE 'sub_%'\" | grep -q 1"
    )
    swiftfox.wait_until_succeeds(
        "sudo -u postgres psql -d dome -tAc \"SELECT count(*) FROM pg_subscription WHERE subname LIKE 'sub_%'\" | grep -q 1"
    )

    lurkingbear.succeed("systemctl start dome-pg-reconcile.service")
    swiftfox.succeed("systemctl start dome-pg-reconcile.service")

    lurkingbear.succeed(
        "sudo -u postgres psql -d dome -c \"INSERT INTO dome_probe VALUES (1, 'from-lurking-bear') ON CONFLICT (id) DO UPDATE SET note = EXCLUDED.note;\""
    )
    swiftfox.wait_until_succeeds(
        "sudo -u postgres psql -d dome -tAc \"SELECT note FROM dome_probe WHERE id = 1\" | grep from-lurking-bear",
        timeout=60,
    )

    peers = lurkingbear.succeed("cat /run/dome/peers").strip().splitlines()
    assert "192.168.67.1" in peers
    assert "192.168.67.2" in peers
    assert "fd67::1" in peers
    assert "fd67::2" in peers
  '';
}
