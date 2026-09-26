{ lib, ... }:
{
  dome = {
    repo.url = lib.mkDefault "https://github.com/Just-another-Muensterhack/dome-ms-infra.git";
    admin.sshKeys = lib.mkDefault [ ];
  };
}
