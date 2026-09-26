{
  config,
  lib,
  inputs,
  ...
}:
let
  cfg = config.dome;
  http = import ./apps/http.nix { inherit config lib; };
  nodes = lib.attrValues cfg.nodes;
  statusHost = "status.dome.ms";
  brand = "${inputs.backend}/web/public";
  theme = builtins.readFile ./status.css;

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
    "id.dome.ms"
    statusHost
  ]
  ++ lib.optional (cfg.apps.enable && cfg.apps.publicHost != null) cfg.apps.publicHost;

  apiEndpoint = lib.optional cfg.apps.enable (endpoint {
    name = "${cfg.apps.web.host}/api";
    group = "services";
    url = "https://${cfg.apps.web.host}/api/";
    conditions = [
      "[STATUS] < 500"
    ];
  });

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
        ui = {
          title = "Status | dome.ms";
          description = "Status of dome.ms nodes, services, and certificates.";
          header = "dome.ms";
          "dashboard-heading" = "Status";
          "dashboard-subheading" = "Nodes, services, and certificates.";
          logo = "/brand/favicon.svg";
          link = "https://dome.ms";
          favicon = {
            default = "/brand/favicon.ico";
            size16x16 = "/brand/favicon.svg";
            size32x32 = "/brand/favicon.svg";
          };
          "custom-css" = theme;
        };
        endpoints = nodeEndpoints ++ serviceEndpoints ++ apiEndpoint ++ certEndpoints;
      };
    };

    services.nginx.virtualHosts.${statusHost} = http.tls // {
      locations = {
        "= /brand/favicon.svg" = {
          alias = "${brand}/favicon.svg";
          extraConfig = ''
            default_type image/svg+xml;
          '';
        };
        "= /brand/favicon.ico" = {
          alias = "${brand}/favicon.ico";
          extraConfig = ''
            default_type image/x-icon;
          '';
        };
        "= /brand/space-grotesk.ttf" = {
          alias = "${brand}/fonts/SpaceGrotesk-VariableFont_wght.ttf";
          extraConfig = ''
            default_type font/ttf;
          '';
        };
        "/" = http.proxy 8085;
      };
    };
  };
}
