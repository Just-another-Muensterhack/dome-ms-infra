{ config, lib, ... }:
{
  imports = [
    ./dome/options.nix
    ./dome/nodes-options.nix
    ./dome/apps-options.nix
    ./dome/acme-options.nix
    ./dome/testing-options.nix
    ./cluster.nix
    ./nodes.nix
    ./sops.nix
    ./comin.nix
    ./testing.nix
    ./node.nix
  ];

  config = lib.mkIf config.dome.enable {
    assertions = [
      {
        assertion = config.dome.admin.sshKeys != [ ];
        message = "dome.admin.sshKeys in modules/cluster.nix must contain at least one public key";
      }
      {
        assertion = config.dome.repo.url != "";
        message = "dome.repo.url in modules/cluster.nix must point to this repository";
      }
    ];

    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    networking.nftables.enable = true;
    networking.firewall.enable = true;

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };

    users.users.root.openssh.authorizedKeys.keys = config.dome.admin.sshKeys;
  };
}
