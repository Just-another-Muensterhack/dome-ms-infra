{ lib, ... }:
let
  inherit (lib) mkOption types;
  nodesLib = import ../../lib/nodes.nix { inherit lib; };
  nodeType = types.submodule (
    { name, ... }:
    {
      options = {
        ipv4 = mkOption {
          type = types.str;
          description = "Host IPv4 address without prefix length.";
        };
        ipv6 = mkOption {
          type = types.str;
          description = "Host IPv6 address without prefix length.";
        };
        fqdn = mkOption {
          type = types.str;
          default = name;
        };
        sequenceOffset = mkOption {
          type = types.ints.between 1 1000;
          default = nodesLib.hashFqdn name;
        };
      };
    }
  );
in
{
  options.dome.nodes = mkOption {
    type = types.attrsOf nodeType;
    default = nodesLib.loadDir ../../nodes;
    description = "Unordered set of cluster peers keyed by fqdn.";
  };
}
