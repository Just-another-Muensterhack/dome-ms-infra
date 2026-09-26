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
        "eth0" = {
          addresses = [
            "46.62.154.20/32"
            "2a01:4f9:c010:82a3::/128"
            "2a01:4f9:c010:82a3::2/64"
          ];
          link = {
            kind = "physical";
            state = "up";
            address = "92:00:09:fb:f8:60";
          };
        };
      };
      routing.routes = [
        {
          to = "0.0.0.0/0";
          via = "172.31.1.1";
          onlink = true;
          dev = "eth0";
        }
        {
          to = "::/0";
          via = "fe80::1";
          dev = "eth0";
        }
      ];
    };
  };

  system.stateVersion = "26.05";
}
