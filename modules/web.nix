{
  config,
  lib,
  inputs,
  pkgs,
  fqdn,
  ...
}:
let
  cfg = config.dome.apps;
  http = import ./apps/http.nix { inherit config lib; };
  system = pkgs.stdenv.hostPlatform.system;
  npmDepsHash = "sha256-h0yOtZXTt5lPbBE3nGhHaS5MD0FD+UqsKd1czmLDBoM=";
  peers = lib.filter (node: node.fqdn != fqdn) (lib.attrValues config.dome.nodes);
  peerUpstreams = lib.concatMapStrings (node: ''
    server ${node.ipv4}:443;
  '') peers;
  webPkg = inputs.backend.packages.${system}.ms-dome-web.overrideAttrs (old: {
    inherit npmDepsHash;
    npmDeps = pkgs.fetchNpmDeps {
      inherit (old) src;
      hash = npmDepsHash;
    };
    env = old.env // {
      NEXT_PUBLIC_API_ORIGIN = "https://${cfg.web.host}";
      NEXT_PUBLIC_KEYCLOAK_URL = "https://${cfg.keycloak.host}";
    };
  });
in
{
  config = lib.mkIf (config.dome.enable && cfg.enable) {
    services.nginx.appendHttpConfig = lib.optionalString (peers != [ ]) ''
      upstream dome_web_asset_peers {
        ${peerUpstreams}
      }
    '';

    services.nginx.virtualHosts.${cfg.web.host} = http.tls // {
      serverAliases = lib.optional (cfg.publicHost != null) cfg.publicHost;
      root = "${webPkg}/share/ms-dome-web";
      locations = {
        "/" = {
          tryFiles = "$uri $uri.html $uri/ /index.html";
          extraConfig = ''
            add_header Cache-Control "no-cache";
          '';
        };
        "/_next/" = {
          tryFiles = if peers == [ ] then "$uri =404" else "$uri @dome_web_assets";
          extraConfig = ''
            add_header Cache-Control "public, max-age=31536000, immutable";
          '';
        };
      } // lib.optionalAttrs (peers != [ ]) {
        "@dome_web_assets" = {
          extraConfig = ''
            if ($http_x_dome_asset_hop = "1") {
              return 404;
            }
            proxy_pass https://dome_web_asset_peers;
            proxy_ssl_server_name on;
            proxy_ssl_name $host;
            proxy_set_header Host $host;
            proxy_set_header X-Dome-Asset-Hop 1;
            proxy_next_upstream error timeout http_404;
            add_header Cache-Control "public, max-age=31536000, immutable";
          '';
        };
      };
    };
  };
}
