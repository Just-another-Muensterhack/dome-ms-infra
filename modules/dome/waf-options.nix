{ lib, ... }:
{
  options.dome.waf = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    blocking = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };
}
