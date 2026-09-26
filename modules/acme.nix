{ config, lib, ... }:
let
  cfg = config.dome.acme;
in
{
  config = lib.mkIf (config.dome.enable && cfg.enable) {
    security.acme = {
      acceptTerms = true;
      defaults = {
        email = cfg.email;
        webroot = "/var/lib/acme/acme-challenge";
        server = lib.mkIf (!cfg.production) "https://acme-staging-v02.api.letsencrypt.org/directory";
      };
    };
  };
}
