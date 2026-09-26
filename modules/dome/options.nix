{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.dome = {
    enable = mkOption {
      type = types.bool;
      default = false;
    };

    admin.sshKeys = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    repo = {
      url = mkOption {
        type = types.str;
        default = "";
      };
      branch = mkOption {
        type = types.str;
        default = "main";
      };
      private = mkOption {
        type = types.bool;
        default = false;
      };
    };

    sops.clusterFile = mkOption {
      type = types.path;
      default = ../../secrets/cluster.yaml;
    };

    discovery = {
      name = mkOption {
        type = types.str;
        default = "nodes.dome.ms";
      };
      interval = mkOption {
        type = types.str;
        default = "1min";
      };
      units = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };

    firewall.peerTCPPorts = mkOption {
      type = types.listOf types.port;
      default = [ ];
    };

    pki = {
      dir = mkOption {
        type = types.str;
        default = "/var/lib/dome/pki";
      };
      domains = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      reloadUnits = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };

    sync = {
      interval = mkOption {
        type = types.str;
        default = "5min";
      };
      command = mkOption {
        type = types.nullOr types.path;
        default = null;
      };
    };
  };
}
