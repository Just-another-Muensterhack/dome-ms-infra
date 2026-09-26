{
  config,
  lib,
  pkgs,
  ...
}:
let
  http = import ./apps/http.nix { inherit config lib; };
  nodes = lib.attrValues config.dome.nodes;
  grafanaHost = "grafana.dome.ms";
  accessLog = "/var/log/nginx/dome.log";
  errorLog = "/var/log/nginx/dome-error.log";
  nodePort = 9100;
  nginxlogPort = 9117;
  wafPort = 3903;
  prometheusPort = 9090;
  grafanaPort = 3001;
  geoipDb = pkgs.dbip-country-lite.mmdb;
  logFormat = lib.concatStringsSep " " [
    "$remote_addr - $remote_user [$time_local]"
    ''"$request" $status $body_bytes_sent''
    ''"$http_referer" "$http_user_agent"''
    "$server_name $geoip2_data_country_code"
  ];
  scrapeTargets =
    name: port:
    map (node: {
      targets = [ "${node.ipv4}:${toString port}" ];
      labels = {
        job = name;
        instance = node.fqdn;
      };
    }) nodes;
  wafProgram = ./monitoring/waf.mtail;
  dashboardJson = ./monitoring/dashboard.json;
in
{
  config = lib.mkIf config.dome.enable {
    dome.firewall.peerTCPPorts = [
      nodePort
      nginxlogPort
      wafPort
    ];

    systemd.tmpfiles.rules = [
      "f ${accessLog} 0644 nginx nginx -"
      "f ${errorLog} 0644 nginx nginx -"
    ];

    services.nginx = {
      additionalModules = [ pkgs.nginxModules.geoip2 ];
      appendHttpConfig = ''
        geoip2 ${geoipDb} {
          $geoip2_data_country_code default=- country iso_code;
        }
        log_format dome '${logFormat}';
        access_log ${accessLog} dome;
        error_log ${errorLog} warn;
      '';
    };

    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "0.0.0.0";
      port = nodePort;
      openFirewall = false;
      enabledCollectors = [
        "systemd"
        "filesystem"
      ];
    };

    services.prometheus.exporters.nginxlog = {
      enable = true;
      listenAddress = "0.0.0.0";
      port = nginxlogPort;
      openFirewall = false;
      group = "nginx";
      settings = {
        consul.enable = false;
        namespaces = [
          {
            name = "dome";
            format = logFormat;
            source.files = [ accessLog ];
            relabel_configs = [
              {
                target_label = "host";
                from = "server_name";
              }
              {
                target_label = "country";
                from = "geoip2_data_country_code";
              }
            ];
          }
        ];
      };
    };

    systemd.services.dome-waf-exporter = {
      description = "Export ModSecurity WAF hits from the nginx error log";
      wantedBy = [ "multi-user.target" ];
      after = [ "nginx.service" ];
      serviceConfig = {
        Type = "simple";
        User = "nginx";
        Group = "nginx";
        ExecStart = "${pkgs.mtail}/bin/mtail --progs ${wafProgram} --logs ${errorLog} --address 0.0.0.0 --port ${toString wafPort}";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    services.prometheus = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = prometheusPort;
      retentionTime = "45d";
      globalConfig.scrape_interval = "15s";
      scrapeConfigs = [
        {
          job_name = "node";
          static_configs = scrapeTargets "node" nodePort;
        }
        {
          job_name = "nginxlog";
          static_configs = scrapeTargets "nginxlog" nginxlogPort;
        }
        {
          job_name = "waf";
          static_configs = scrapeTargets "waf" wafPort;
        }
      ];
    };

    sops.secrets."grafana/admin_password" = {
      sopsFile = config.dome.sops.clusterFile;
      owner = "grafana";
      group = "grafana";
      restartUnits = [ "grafana.service" ];
    };

    sops.secrets."grafana/secret_key" = {
      sopsFile = config.dome.sops.clusterFile;
      owner = "grafana";
      group = "grafana";
      restartUnits = [ "grafana.service" ];
    };

    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = grafanaPort;
          domain = grafanaHost;
          root_url = "https://${grafanaHost}/";
        };
        security = {
          admin_user = "admin";
          admin_password = "$__file{${config.sops.secrets."grafana/admin_password".path}}";
          secret_key = "$__file{${config.sops.secrets."grafana/secret_key".path}}";
        };
        users.allow_sign_up = false;
        analytics.reporting_enabled = false;
      };
      provision = {
        enable = true;
        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "Prometheus";
              type = "prometheus";
              access = "proxy";
              url = "http://127.0.0.1:${toString prometheusPort}";
              isDefault = true;
              uid = "prometheus";
              editable = false;
            }
          ];
        };
        dashboards.settings.providers = [
          {
            name = "dome";
            type = "file";
            disableDeletion = true;
            updateIntervalSeconds = 60;
            options.path = pkgs.writeTextDir "dome-cluster.json" (builtins.readFile dashboardJson);
          }
        ];
      };
    };

    services.nginx.virtualHosts.${grafanaHost} = http.tls // {
      locations."/" = http.proxy grafanaPort;
    };
  };
}
