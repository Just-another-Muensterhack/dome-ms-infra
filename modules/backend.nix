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
  mediaCsp = lib.concatStringsSep "; " [
    "default-src 'none'"
    "script-src 'self' 'unsafe-inline' https: http:"
    "img-src 'self' https: http: data:"
    "style-src 'self' 'unsafe-inline' https: http:"
    "font-src 'self' https: http: data:"
    "connect-src 'self' https: http:"
    "base-uri 'none'"
    "form-action 'none'"
    "frame-ancestors ${lib.concatStringsSep " " ([ "'self'" ] ++ corsOrigins)}"
  ];
  stateRoot = "/var/lib/dome.ms";
  mediaRoot = "${stateRoot}/data";
  nginxConfigDir = "${stateRoot}/nginx-desired";
  nginxLiveDir = "${stateRoot}/nginx";
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

    sops.secrets."backend/model_api_key" = {
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
        MODEL_API_KEY=${config.sops.placeholder."backend/model_api_key"}
        MODEL_API_URL=${cfg.backend.modelApiUrl}
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
      "d ${nginxLiveDir} 0755 dome dome -"
    ];

    systemd.services.dome-backend = {
      description = "dome.ms backend";
      wantedBy = [ "multi-user.target" ];
      after = [
        "postgresql-setup.service"
        "dome-pg-app-roles.service"
        "dome-pg-reconcile.service"
        "keycloak.service"
      ];
      requires = [
        "postgresql-setup.service"
        "dome-pg-app-roles.service"
      ];
      wants = [
        "dome-pg-reconcile.service"
        "keycloak.service"
      ];
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
          "NGINX_CERT_ROOT=/var/lib/dome/certs/live"
          "NGINX_RESOLVER=127.0.0.1"
          "DOME_BASE_DOMAIN=${cfg.web.host}"
        ];
        ExecStart = "${backendPkg}/bin/ms-dome --timeout 360";
        Restart = "on-failure";
        RestartSec = "10s";
        WorkingDirectory = "/var/lib/dome-backend";
        StateDirectory = "dome-backend";
      };
    };

    systemd.services.dome-sync-nginx = {
      description = "Render dome nginx site configs from the database";
      after = [
        "dome-backend.service"
        "postgresql.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "dome";
        Group = "dome";
        EnvironmentFile = config.sops.templates."dome-backend.env".path;
        Environment = [
          "MEDIA_ROOT=${mediaRoot}"
          "NGINX_MEDIA_ROOT=${mediaRoot}"
          "NGINX_CONFIG_DIR=${nginxConfigDir}"
          "NGINX_TEMPLATE_DIR=${nginxTemplateDir}"
          "NGINX_CERT_ROOT=/var/lib/dome/certs/live"
          "NGINX_RESOLVER=127.0.0.1"
        ];
        ExecStart = "${backendPkg}/bin/ms-dome-manage sync_nginx";
      };
    };

    systemd.timers.dome-sync-nginx = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = config.dome.sync.interval;
      };
    };

    services.nginx = {
      commonHttpConfig = ''
        include ${nginxLiveDir}/*.conf;
      '';
      virtualHosts.${cfg.backend.host} = http.tls // {
        locations."/" = http.proxy cfg.backend.port // {
          extraConfig = ''
            proxy_read_timeout 360s;
          '';
        };
      };
      virtualHosts.${cfg.web.host}.locations = {
        "/api/" = http.proxy cfg.backend.port // {
          extraConfig = ''
            proxy_read_timeout 360s;
          '';
        };
        "/media/" = {
          alias = "${mediaRoot}/";
          extraConfig = ''
            add_header Content-Security-Policy "${mediaCsp}" always;
          '';
        };
      };
    };

    systemd.paths.dome-nginx-reload = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = nginxLiveDir;
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
