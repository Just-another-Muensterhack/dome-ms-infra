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
      parameters.hooks.dhcp.script = pkgs.writeScript "ifstate-udhcpc.sh" ''
        ${lib.getExe' pkgs.busybox "udhcpc"} --quit --now -i "$IFS_IFNAME" -b --script ${pkgs.busybox}/default.script
      '';
      interfaces = {
        enp1s0 = {
          addresses = [ "2a01:4f9:c015:5199::/64" ];
          hooks = [ { name = "dhcp"; } ];
          link = {
            kind = "physical";
            state = "up";
          };
        };
      };
      routing.routes = [
        {
          to = "::/0";
          via = "fe80::1";
          dev = "enp1s0";
        }
      ];
    };
  };

  system.stateVersion = "26.05";
}
