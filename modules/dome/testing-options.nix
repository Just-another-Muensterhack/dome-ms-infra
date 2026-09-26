{ lib, ... }:
{
  options.dome.testing = {
    enable = lib.mkEnableOption "dome VM/integration test mode";
  };
}
