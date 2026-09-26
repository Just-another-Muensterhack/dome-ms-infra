{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.dome.acme = {
    enable = mkOption {
      type = types.bool;
      default = true;
    };

    email = mkOption {
      type = types.str;
      default = "hostmaster@dome.ms";
    };

    production = mkOption {
      type = types.bool;
      default = false;
    };
  };
}
