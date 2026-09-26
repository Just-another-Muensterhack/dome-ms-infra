{ config, lib, ... }:
{
  config = lib.mkIf config.dome.enable {
    boot.initrd = {
      systemd = {
        enable = true;
        network = {
          enable = true;
          networks."10-uplink" = {
            matchConfig.Name = "en* eth*";
            networkConfig.DHCP = "yes";
          };
        };
      };

      network = {
        enable = true;
        ssh = {
          enable = true;
          port = 2222;
          hostKeys = [ "/etc/ssh/ssh_host_ed25519_key" ];
          authorizedKeys = config.dome.admin.sshKeys;
        };
      };
    };
  };
}
