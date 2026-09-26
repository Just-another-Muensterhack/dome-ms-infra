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
  backendPkg = inputs.backend.packages.${system}.ms-dome;
  corsOrigins = map (host: "https://${host}") (
    [
      cfg.web.host
      cfg.backend.host
      cfg.keycloak.host
    ]
    ++ lib.optional (cfg.publicHost != null) cfg.publicHost
  );
in
{
  config = lib.mkIf (config.dome.enable && cfg.enable) {
    sops.secrets."keycloak/client_secret" = {
      sopsFile = config.dome.sops.clusterFile;
    };

    sops.templates."dome-backend.env" = {
      content = ''
        PORT=${toString cfg.backend.port}
        POSTGRES_HOST=127.0.0.1
        POSTGRES_PORT=5432
        POSTGRES_USER=dome
        POSTGRES_PASSWORD=${config.sops.placeholder."postgres/dome_password"}
        POSTGRES_DB=dome
        KEYCLOAK_URL=http://127.0.0.1:${toString cfg.keycloak.port}
        KEYCLOAK_PUBLIC_URL=https://${cfg.keycloak.host}
        KEYCLOAK_REALM=msdome
        KEYCLOAK_CLIENT_ID=msdome-backend
        KEYCLOAK_CLIENT_SECRET=${config.sops.placeholder."keycloak/client_secret"}
        DJANGO_ALLOWED_HOSTS=*
        CORS_ALLOWED_ORIGINS=${lib.concatStringsSep "," corsOrigins}
        DEBUG=false
      '';
      owner = "dome";
      group = "dome";
    };

    users.users.dome = {
      isSystemUser = true;
      group = "dome";
      home = "/var/lib/dome-backend";
      createHome = true;
    };
    users.groups.dome = { };

    systemd.services.dome-backend = {
      description = "dome.ms backend";
      wantedBy = [ "multi-user.target" ];
      after = [
        "postgresql-setup.service"
        "dome-pg-app-roles.service"
        "keycloak.service"
      ];
      requires = [
        "postgresql-setup.service"
        "dome-pg-app-roles.service"
      ];
      wants = [ "keycloak.service" ];
      serviceConfig = {
        Type = "simple";
        User = "dome";
        Group = "dome";
        EnvironmentFile = config.sops.templates."dome-backend.env".path;
        ExecStart = "${backendPkg}/bin/ms-dome";
        Restart = "on-failure";
        RestartSec = "10s";
        WorkingDirectory = "/var/lib/dome-backend";
        StateDirectory = "dome-backend";
      };
    };

    services.nginx.virtualHosts.${cfg.backend.host} = http.tls // {
      locations."/" = http.proxy cfg.backend.port;
    };
  };
}
