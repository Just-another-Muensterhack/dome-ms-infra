{
  config,
  lib,
  pkgs,
  fqdn,
  ...
}:
let
  cfg = config.dome.acme;
  apps = config.dome.apps;
  pki = config.dome.pki.dir;
  desiredNginx = "/var/lib/dome.ms/nginx-desired";
  certLive = "/var/lib/dome/certs/live";
  challengeDir = "/var/lib/acme/acme-challenge";
  challengePort = 8099;
  fanoutPort = 8098;
  certName = "dome.ms";
  sitesState = "/var/lib/acme/sites-lego";
  failureBackoffMinutes = 10;
  acmeServer =
    if cfg.production then
      "https://acme-v02.api.letsencrypt.org/directory"
    else
      "https://acme-staging-v02.api.letsencrypt.org/directory";
  peerIps = map (node: node.ipv4) (
    lib.filter (node: node.fqdn != fqdn) (lib.attrValues config.dome.nodes)
  );
  httpDomains = lib.unique (
    [ certName ]
    ++ lib.optionals apps.enable [
      apps.web.host
      apps.backend.host
      apps.keycloak.host
    ]
    ++ [ "status.dome.ms" ]
  );
  domainArgs = lib.concatMapStringsSep " " (domain: "-d ${lib.escapeShellArg domain}") httpDomains;
  etcdEnv = ''
    export ETCDCTL_CACERT=${pki}/ca.crt
    export ETCDCTL_CERT=${pki}/node.crt
    export ETCDCTL_KEY=${pki}/node.key
    export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
  '';
  challengeFileLocation = {
    root = challengeDir;
    extraConfig = "default_type text/plain;";
  };
  challengeLocations = {
    "/.well-known/acme-challenge/" = challengeFileLocation // {
      extraConfig = ''
        default_type text/plain;
        ${lib.optionalString (peerIps != [ ]) "try_files $uri @dome_acme_peers;"}
      '';
    };
  }
  // lib.optionalAttrs (peerIps != [ ]) {
    "@dome_acme_peers" = {
      proxyPass = "http://dome_acme_peers";
      extraConfig = ''
        proxy_next_upstream error timeout http_404;
        proxy_set_header Host $host;
      '';
    };
  };
  vhostNames = lib.unique (
    [ "status.dome.ms" ]
    ++ lib.optionals apps.enable [
      apps.web.host
      apps.backend.host
      apps.keycloak.host
    ]
  );
  issueLocked = pkgs.writeShellScript "dome-acme-http-locked" ''
    set -euo pipefail
    ${etcdEnv}
    etcdctl=${pkgs.etcd}/bin/etcdctl
    openssl=${pkgs.openssl}/bin/openssl
    dest=/var/lib/acme/${certName}
    state=/var/lib/acme/http-lego
    live=${certLive}/${certName}

    is_public() {
      local pem=$1 issuer end end_epoch now
      [ -s "$pem" ] || return 1
      issuer=$($openssl x509 -in "$pem" -noout -issuer 2>/dev/null || true)
      case "$issuer" in
        *[Mm]inica*) return 1 ;;
      esac
      [ -n "$issuer" ] || return 1
      end=$($openssl x509 -in "$pem" -noout -enddate | cut -d= -f2)
      end_epoch=$(date -d "$end" +%s)
      now=$(date +%s)
      [ $((end_epoch - now)) -gt 2592000 ]
    }

    install_pem() {
      local src_full=$1 src_key=$2 src_chain=$3
      install -d -m 0750 -o acme -g nginx "$dest" "$live"
      cp -f "$src_full" "$dest/fullchain.pem"
      cp -f "$src_key" "$dest/key.pem"
      if [ -n "$src_chain" ] && [ -s "$src_chain" ]; then
        cp -f "$src_chain" "$dest/chain.pem"
      else
        cp -f "$src_full" "$dest/chain.pem"
      fi
      ln -sfn fullchain.pem "$dest/cert.pem"
      cat "$dest/key.pem" "$dest/fullchain.pem" > "$dest/full.pem"
      touch "$dest/acme-success"
      chown -R acme:nginx "$dest"
      chmod 0640 "$dest/key.pem" "$dest/full.pem"
      chmod 0644 "$dest/fullchain.pem" "$dest/chain.pem" "$dest/cert.pem" "$dest/acme-success"
      cp -f "$dest/fullchain.pem" "$live/fullchain.pem"
      cp -f "$dest/key.pem" "$live/key.pem"
      cp -f "$dest/chain.pem" "$live/chain.pem"
      chmod 0640 "$live/key.pem"
      chgrp nginx "$live/key.pem" 2>/dev/null || true
      ${pkgs.systemd}/bin/systemctl reload nginx.service
    }

    publish() {
      local full_hash
      $etcdctl put /dome/certs/${certName}/fullchain.pem < "$dest/fullchain.pem" >/dev/null
      $etcdctl put /dome/certs/${certName}/key.pem < "$dest/key.pem" >/dev/null
      $etcdctl put /dome/certs/${certName}/chain.pem < "$dest/chain.pem" >/dev/null
      full_hash=$(sha256sum "$dest/fullchain.pem" | cut -d' ' -f1)
      $etcdctl put /dome/certs/${certName}/fullchain.pem.hash "$full_hash" >/dev/null
      $etcdctl put /dome/certs/${certName}/key.pem.hash "$(sha256sum "$dest/key.pem" | cut -d' ' -f1)" >/dev/null
      $etcdctl put /dome/certs/${certName}/chain.pem.hash "$(sha256sum "$dest/chain.pem" | cut -d' ' -f1)" >/dev/null
    }

    pull_etcd() {
      local tmp=$1
      $etcdctl get /dome/certs/${certName}/fullchain.pem --print-value-only > "$tmp/fullchain.pem" || true
      $etcdctl get /dome/certs/${certName}/key.pem --print-value-only > "$tmp/key.pem" || true
      $etcdctl get /dome/certs/${certName}/chain.pem --print-value-only > "$tmp/chain.pem" || true
      if is_public "$tmp/fullchain.pem" && [ -s "$tmp/key.pem" ]; then
        install_pem "$tmp/fullchain.pem" "$tmp/key.pem" "$tmp/chain.pem"
        return 0
      fi
      return 1
    }

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    if pull_etcd "$tmp"; then
      exit 0
    fi
    if is_public "$dest/fullchain.pem"; then
      publish
      exit 0
    fi

    install -d -m 0755 ${challengeDir}/.well-known/acme-challenge
    install -d -m 0700 "$state"
    ${pkgs.lego}/bin/lego run --accept-tos \
      --email ${lib.escapeShellArg cfg.email} \
      --http \
      --http.webroot ${challengeDir} \
      --http.delay 2s \
      --server ${lib.escapeShellArg acmeServer} \
      --path "$state" \
      --key-type ec256 \
      ${domainArgs}
    crt=$(find "$state/certificates" -name '*.crt' ! -name '*.issuer.crt' | head -n 1)
    base=$(basename "$crt" .crt)
    install_pem "$crt" "$state/certificates/$base.key" "$state/certificates/$base.issuer.crt"
    publish
  '';
  issue = pkgs.writeShellScript "dome-acme-http" ''
    set -euo pipefail
    ${etcdEnv}
    etcdctl=${pkgs.etcd}/bin/etcdctl
    for _ in $(seq 1 30); do
      if $etcdctl endpoint health >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
    exec $etcdctl lock /dome/acme/http-issue --ttl=600 ${issueLocked}
  '';
  siteCerts = pkgs.writeShellScript "dome-acme-sites" ''
    set -euo pipefail
    install -d -m 0755 ${certLive} ${challengeDir}/.well-known/acme-challenge
    install -d -m 0700 ${sitesState} ${sitesState}/failed
    [ -d ${desiredNginx} ] || exit 0
    issued=0
    for conf in ${desiredNginx}/*.conf; do
      [ -e "$conf" ] || continue
      name=$(basename "$conf" .conf)
      case "$name" in
        _wildcard.*|*/*|.*) continue ;;
      esac
      dest=${certLive}/$name
      if [ -f "$dest/key.pem" ] && ${pkgs.openssl}/bin/openssl x509 -in "$dest/fullchain.pem" -noout -checkend 2592000 >/dev/null 2>&1; then
        continue
      fi
      failed=${sitesState}/failed/$name
      if [ -n "$(find "$failed" -mmin -${toString failureBackoffMinutes} 2>/dev/null)" ]; then
        continue
      fi
      if ! ${pkgs.lego}/bin/lego run --accept-tos \
        --email ${lib.escapeShellArg cfg.email} \
        --http \
        --http.webroot ${challengeDir} \
        --http.delay 2s \
        --server ${lib.escapeShellArg acmeServer} \
        --path ${sitesState} \
        --key-type ec256 \
        --domains "$name"; then
        echo "issuing $name failed, retrying in ${toString failureBackoffMinutes}min" >&2
        touch "$failed"
        continue
      fi
      rm -f "$failed"
      install -d -m 0755 "$dest"
      cp -f ${sitesState}/certificates/$name.crt "$dest/fullchain.pem"
      cp -f ${sitesState}/certificates/$name.key "$dest/key.pem"
      chmod 0640 "$dest/key.pem"
      chgrp nginx "$dest/key.pem" 2>/dev/null || true
      issued=1
    done
    if [ "$issued" = 1 ]; then
      ${pkgs.systemd}/bin/systemctl start --no-block dome-sync.service || true
    fi
  '';
in
{
  config = lib.mkIf (config.dome.enable && cfg.enable) {
    users.users.acme.extraGroups = [ "dome-pki" ];

    dome.firewall.peerTCPPorts = [ challengePort ];

    systemd.tmpfiles.rules = [
      "d ${challengeDir} 0755 acme nginx -"
      "d ${challengeDir}/.well-known 0755 acme nginx -"
      "d ${challengeDir}/.well-known/acme-challenge 0755 acme nginx -"
    ];

    services.nginx.appendHttpConfig = lib.optionalString (peerIps != [ ]) ''
      upstream dome_acme_peers {
        ${lib.concatMapStrings (ip: ''
          server ${ip}:${toString challengePort};
        '') peerIps}
      }

      server {
        listen 127.0.0.1:${toString fanoutPort};
        server_name _;
        location / {
          proxy_pass http://dome_acme_peers;
          proxy_next_upstream error timeout http_404;
          proxy_set_header Host $host;
        }
      }
    '';

    services.nginx.virtualHosts = {
      "_" = {
        default = true;
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
          {
            addr = "[::]";
            port = 80;
          }
        ];
        locations = challengeLocations // {
          "/" = {
            return = "404";
          };
        };
      };
      "dome-acme-challenge" = {
        serverName = "dome-acme-challenge.invalid";
        listen = [
          {
            addr = "0.0.0.0";
            port = challengePort;
          }
          {
            addr = "[::]";
            port = challengePort;
          }
        ];
        locations = {
          "/.well-known/acme-challenge/" = challengeFileLocation;
          "/" = {
            return = "404";
          };
        };
      };
    }
    // lib.optionalAttrs (peerIps != [ ]) (
      lib.mapAttrs (_: _: {
        acmeFallbackHost = "127.0.0.1:${toString fanoutPort}";
      }) (lib.genAttrs vhostNames (_: null))
    );

    security.acme = {
      acceptTerms = true;
      defaults = {
        email = cfg.email;
        server = lib.mkIf (!cfg.production) "https://acme-staging-v02.api.letsencrypt.org/directory";
      };
      certs.${certName} = {
        domain = certName;
        extraDomainNames = lib.filter (name: name != certName) httpDomains;
        webroot = challengeDir;
        group = "nginx";
        reloadServices = [ "nginx.service" ];
      };
    };

    systemd.services."acme-order-renew-${certName}" = {
      serviceConfig = {
        ExecStart = lib.mkForce "${pkgs.coreutils}/bin/true";
        Restart = lib.mkForce "no";
      };
    };

    systemd.services.dome-acme-http = {
      description = "Issue the shared HTTP-01 certificate";
      after = [
        "nginx.service"
        "etcd.service"
        "network-online.target"
      ];
      wants = [
        "nginx.service"
        "etcd.service"
      ];
      path = with pkgs; [
        coreutils
        etcd
        findutils
        lego
        openssl
        systemd
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = issue;
        TimeoutStartSec = "10min";
        Restart = "on-failure";
        RestartSec = "5min";
      };
      startLimitIntervalSec = 3600;
      startLimitBurst = 4;
    };

    systemd.timers.dome-acme-http = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "12h";
      };
    };

    systemd.services.dome-acme-sites = {
      description = "Issue HTTP-01 certificates for non-dome.ms site domains";
      after = [
        "nginx.service"
        "etcd.service"
        "dome-sync-nginx.service"
      ];
      path = with pkgs; [
        coreutils
        etcd
        findutils
        lego
        openssl
        systemd
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = siteCerts;
        TimeoutStartSec = "30min";
      };
    };

    systemd.timers.dome-acme-sites = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "5min";
      };
    };
  };
}
