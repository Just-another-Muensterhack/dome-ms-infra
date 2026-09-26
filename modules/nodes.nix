{
  config,
  lib,
  ...
}:
let
  nodesLib = import ../lib/nodes.nix { inherit lib; };
  cfg = config.dome;
  platformHosts = lib.optionals cfg.apps.enable [
    cfg.apps.web.host
    cfg.apps.backend.host
    cfg.apps.keycloak.host
  ];
  nodes = cfg.nodes;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = nodes != { };
        message = "dome.nodes must contain at least one peer (nodes/*.nix or dome.nodes)";
      }
      (nodesLib.assertUniqueOffsets nodes)
    ];

    environment.etc."dome/nodes" = {
      text = nodesLib.nodesFile nodes;
      mode = "0644";
    };

    networking.hosts = lib.mkMerge (
      map (node: {
        ${node.ipv4} = [ node.fqdn ] ++ nodesLib.sharedNames ++ platformHosts;
        ${node.ipv6} = [ node.fqdn ] ++ nodesLib.sharedNames ++ platformHosts;
      }) (lib.attrValues nodes)
    );
  };
}
