{
  imports = [ ./disko.nix ];

  boot.loader = {
    grub = {
      enable = true;
      device = "/dev/sda";
      efiSupport = true;
      efiInstallAsRemovable = true;
      copyKernels = true;
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

  system.stateVersion = "26.05";
}
