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
  stateRoot = "/var/lib/dome.ms";
  mediaRoot = "${stateRoot}/data";
  nginxConfigDir = "${stateRoot}/nginx";
  nginxTemplateDir = pkgs.runCommand "dome-nginx-templates" { } ''
    mkdir -p $out
    cp ${./nginx/static.conf} $out/static.conf
    cp ${./nginx/proxy.conf} $out/proxy.conf
  '';
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

    systemd.tmpfiles.rules = [
      "d ${stateRoot} 0755 dome dome -"
      "d ${mediaRoot} 0755 dome dome -"
      "d ${nginxConfigDir} 0755 dome dome -"
    ];

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
        Environment = [
          "MEDIA_ROOT=${mediaRoot}"
          "NGINX_MEDIA_ROOT=${mediaRoot}"
          "NGINX_CONFIG_DIR=${nginxConfigDir}"
          "NGINX_TEMPLATE_DIR=${nginxTemplateDir}"
          "DOME_BASE_DOMAIN=${cfg.web.host}"
        ];
        ExecStart = "${backendPkg}/bin/ms-dome";
        Restart = "on-failure";
        RestartSec = "10s";
        WorkingDirectory = "/var/lib/dome-backend";
        StateDirectory = "dome-backend";
      };
    };

    services.nginx = {
      commonHttpConfig = ''
        include ${nginxConfigDir}/*.conf;
      '';
      virtualHosts.${cfg.backend.host} = http.tls // {
        locations."/" = http.proxy cfg.backend.port;
      };
    };

    systemd.paths.dome-nginx-reload = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = nginxConfigDir;
        Unit = "dome-nginx-reload.service";
      };
    };

    systemd.services.dome-nginx-reload = {
      description = "Reload nginx after dome site configs change";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "dome-nginx-reload" ''
          sleep 1
          ${config.services.nginx.package}/bin/nginx -t -c /etc/nginx/nginx.conf
          ${pkgs.systemd}/bin/systemctl try-reload-or-restart nginx.service
        '';
      };
    };
  };
}
