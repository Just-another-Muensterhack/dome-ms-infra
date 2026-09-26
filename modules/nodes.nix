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
    ]
    ++ map (node: {
      assertion = !lib.hasInfix "/" node.ipv4 && !lib.hasInfix "/" node.ipv6;
      message = "${node.fqdn}: ipv4/ipv6 must be bare addresses without /prefix (got ${node.ipv4} / ${node.ipv6})";
    }) (lib.attrValues nodes);

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
