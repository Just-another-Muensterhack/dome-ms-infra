{
  config,
  lib,
  hostPath,
  ...
}:
{
  config = lib.mkIf config.dome.enable {
    sops = {
      defaultSopsFile = hostPath + "/secrets/secrets.yaml";
      age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    };
  };
}
