{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dome;
  http = import ./apps/http.nix { inherit config lib; };
  nodes = lib.attrValues cfg.nodes;
  statusHost = "status.dome.ms";

  endpoint =
    {
      name,
      group,
      url,
      conditions ? [ "[CONNECTED] == true" ],
    }:
    {
      inherit
        name
        group
        url
        conditions
        ;
      interval = "1m";
      client.insecure = false;
    };

  nodeEndpoints = lib.concatMap (node: [
    (endpoint {
      name = "${node.fqdn} https";
      group = "nodes";
      url = "tcp://${node.ipv4}:443";
    })
    (endpoint {
      name = "${node.fqdn} dns";
      group = "nodes";
      url = "tcp://${node.ipv4}:53";
    })
  ]) nodes;

  serviceHosts = [
    "dome.ms"
    "api.dome.ms"
    "id.dome.ms"
    statusHost
  ];

  serviceEndpoints = map (
    host:
    endpoint {
      name = host;
      group = "services";
      url = "https://${host}";
      conditions = [
        "[STATUS] < 500"
      ];
    }
  ) serviceHosts;
in
{
  config = lib.mkIf cfg.enable {
    services.gatus = {
      enable = true;
      settings = {
        web = {
          address = "127.0.0.1";
          port = 8085;
        };
        storage = {
          type = "memory";
        };
        endpoints = nodeEndpoints ++ serviceEndpoints;
      };
    };

    services.nginx.virtualHosts.${statusHost} = http.tls // {
      locations."/" = http.proxy 8085;
    };
  };
}
