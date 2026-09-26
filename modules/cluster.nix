{ lib, ... }:
{
  dome = {
    repo.url = lib.mkDefault "";
    admin.sshKeys = lib.mkDefault [ ];
  };
}
