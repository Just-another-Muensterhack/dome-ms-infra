{ pkgs, lib, ... }:
{
  imports = [ ./disko.nix ];

  boot.loader = {
    grub = {
      enable = true;
      device = "/dev/sda";
      efiSupport = true;
      efiInstallAsRemovable = true;
    };
    efi.canTouchEfiVariables = false;
  };

  boot.initrd.availableKernelModules = [
    "ahci"
    "nvme"
    "sd_mod"
    "xhci_pci"
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "virtio_net"
  ];

  networking.ifstate = {
    enable = true;
    settings = {
      interfaces = {
        "@IFACE@" = {
          addresses = [
            "@IPV4@/@IPV4_PREFIX@"
            "@IPV6@/@IPV6_PREFIX@"
          ];
          link = {
            kind = "physical";
            state = "up";
            address = "@MAC@";
          };
        };
      };
      routing.routes = [
        {
          to = "0.0.0.0/0";
          via = "@IPV4_GATEWAY@";
          onlink = true;
          dev = "@IFACE@";
        }
        {
          to = "::/0";
          via = "@IPV6_GATEWAY@";
          dev = "@IFACE@";
        }
      ];
    };
  };

  system.stateVersion = "26.05";
}
