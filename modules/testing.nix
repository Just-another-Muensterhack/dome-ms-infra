{ config, lib, ... }:
{
  config = lib.mkIf config.dome.testing.enable {
    dome.apps.enable = true;
    dome.acme.enable = false;

    systemd.services.nginx.wantedBy = lib.mkForce [ "multi-user.target" ];
    systemd.services.keycloak.wantedBy = lib.mkForce [ "multi-user.target" ];
    systemd.services.dome-backend.wantedBy = lib.mkForce [ "multi-user.target" ];

    services.comin.enable = lib.mkForce false;

    boot.initrd.network.ssh.enable = lib.mkForce false;
    boot.initrd.network.enable = lib.mkForce false;

    sops.age.sshKeyPaths = lib.mkForce [ ];
  };
}
