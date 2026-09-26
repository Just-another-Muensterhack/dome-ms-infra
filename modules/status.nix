{ config, lib, ... }:
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
      interval ? "1m",
    }:
    {
      inherit
        name
        group
        url
        conditions
        interval
        ;
      client.insecure = false;
    };

  nodeEndpoints = lib.concatMap (node: [
    (endpoint {
      name = "${node.fqdn} dns";
      group = "nodes";
      url = "tcp://${node.ipv4}:53";
    })
    (endpoint {
      name = "${node.fqdn} ping";
      group = "nodes";
      url = "icmp://${node.ipv4}";
    })
  ]) nodes;

  serviceHosts = [
    "dome.ms"
    "api.dome.ms"
    "id.dome.ms"
    statusHost
  ]
  ++ lib.optional (cfg.apps.enable && cfg.apps.publicHost != null) cfg.apps.publicHost;

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

  certEndpoints = map (
    host:
    endpoint {
      name = host;
      group = "certs";
      url = "https://${host}";
      interval = "15m";
      conditions = [
        "[CONNECTED] == true"
        "[CERTIFICATE_EXPIRATION] > 336h"
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
        endpoints = nodeEndpoints ++ serviceEndpoints ++ certEndpoints;
      };
    };

    services.nginx.virtualHosts.${statusHost} = http.tls // {
      locations."/" = http.proxy 8085;
    };
  };
}
