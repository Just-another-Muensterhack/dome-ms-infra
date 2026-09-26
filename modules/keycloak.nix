{
  config,
  lib,
  ...
}:
let
  cfg = config.dome.apps;
  http = import ./apps/http.nix { inherit config lib; };
  realm = import ./keycloak/realm.nix {
    webHost = cfg.web.host;
    publicHost = cfg.publicHost;
    clientSecret = config.sops.placeholder."keycloak/client_secret";
  };
in
{
  config = lib.mkIf (config.dome.enable && cfg.enable) {
    dome.pki = {
      domains = [
        cfg.web.host
        cfg.backend.host
        cfg.keycloak.host
      ];
      reloadUnits = [ "nginx.service" ];
    };

    sops.secrets."keycloak/admin_password" = {
      sopsFile = config.dome.sops.clusterFile;
    };

    sops.templates."keycloak-bootstrap.env" = {
      content = ''
        KC_BOOTSTRAP_ADMIN_USERNAME=admin
        KC_BOOTSTRAP_ADMIN_PASSWORD=${config.sops.placeholder."keycloak/admin_password"}
      '';
    };

    sops.templates."msdome.json" = {
      content = builtins.toJSON realm;
      mode = "0444";
    };

    services.keycloak = {
      enable = true;
      database = {
        type = "postgresql";
        createLocally = false;
        host = "localhost";
        port = 5432;
        name = "keycloak";
        username = "keycloak";
        passwordFile = config.sops.secrets."keycloak/db_password".path;
        useSSL = false;
      };
      realmFiles = [ config.sops.templates."msdome.json".path ];
      settings = {
        hostname = "https://${cfg.keycloak.host}";
        hostname-strict = false;
        hostname-backchannel-dynamic = true;
        http-enabled = true;
        http-port = cfg.keycloak.port;
        health-enabled = true;
        proxy-headers = "xforwarded";
      };
    };

    systemd.services.keycloak = {
      after = [
        "postgresql-setup.service"
        "dome-pg-app-roles.service"
      ];
      requires = [
        "postgresql-setup.service"
        "dome-pg-app-roles.service"
      ];
      serviceConfig.EnvironmentFile = [
        config.sops.templates."keycloak-bootstrap.env".path
      ];
    };

    services.nginx = {
      enable = true;
      virtualHosts.${cfg.keycloak.host} = http.tls // {
        locations."/" = http.proxy cfg.keycloak.port;
      };
    };

    users.users.nginx.extraGroups = [ "dome-pki" ];

    systemd.services.nginx = lib.mkIf (!config.dome.acme.enable) {
      after = [ "dome-pki.service" ];
      requires = [ "dome-pki.service" ];
    };
  };
}
