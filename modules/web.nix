{
  config,
  lib,
  inputs,
  pkgs,
  ...
}:
let
  cfg = config.dome.apps;
  http = import ./apps/http.nix { inherit config lib; };
  system = pkgs.stdenv.hostPlatform.system;
  webPkg = inputs.backend.packages.${system}.ms-dome-web.overrideAttrs (old: {
    npmDeps = pkgs.fetchNpmDeps {
      inherit (old) src;
      hash = "sha256-h0yOtZXTt5lPbBE3nGhHaS5MD0FD+UqsKd1czmLDBoM=";
    };
    env = old.env // {
      NEXT_PUBLIC_API_ORIGIN = "https://${cfg.backend.host}";
      NEXT_PUBLIC_KEYCLOAK_URL = "https://${cfg.keycloak.host}";
    };
  });
in
{
  config = lib.mkIf (config.dome.enable && cfg.enable) {
    services.nginx.virtualHosts.${cfg.web.host} = http.tls // {
      serverAliases = lib.optional (cfg.publicHost != null) cfg.publicHost;
      root = "${webPkg}/share/ms-dome-web";
      locations."/" = {
        tryFiles = "$uri $uri.html $uri/ /index.html";
      };
    };
  };
}
