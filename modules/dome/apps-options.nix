{ lib, ... }:
{
  options.dome.apps = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    publicHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    keycloak = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "id.dome.ms";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
      };
    };

    backend = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "api.dome.ms";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8000;
      };
    };

    web = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "dome.ms";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 3000;
      };
    };
  };
}
