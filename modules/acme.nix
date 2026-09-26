{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dome.acme;
  pki = config.dome.pki.dir;
  desiredNginx = "/var/lib/dome.ms/nginx-desired";
  certLive = "/var/lib/dome/certs/live";
  challengeDir = "/var/lib/acme/acme-challenge";
  etcdctl = "${pkgs.etcd}/bin/etcdctl --cacert ${pki}/ca.crt --cert ${pki}/node.crt --key ${pki}/node.key --endpoints https://127.0.0.1:2379";
  reloadStamp = "/run/dome/dns-reload";
  dnsHook = pkgs.writeShellScript "dome-acme-dns" ''
    set -euo pipefail
    action=$1
    domain=$2
    token=$3
    key="/dome/dns/''${domain}"
    name=$(printf '%s' "$domain" | sed 's/\.$//')
    request_reload() {
      date +%s > ${reloadStamp}
    }
    case "$action" in
      present)
        ${etcdctl} put "$key" "$token" >/dev/null
        request_reload
        for _ in $(seq 1 90); do
          got=$(${pkgs.knot-dns}/bin/kdig +short @"127.0.0.1" TXT "$name" 2>/dev/null | tr -d '"' || true)
          if [ "$got" = "$token" ]; then
            exit 0
          fi
          sleep 2
        done
        echo "TXT record for $name did not appear" >&2
        exit 1
        ;;
      cleanup)
        ${etcdctl} del "$key" >/dev/null || true
        request_reload
        ;;
      *)
        echo "usage: $0 present|cleanup <domain> <token>" >&2
        exit 1
        ;;
    esac
  '';
  execEnv = pkgs.writeText "dome-acme-exec.env" ''
    EXEC_PATH=${dnsHook}
  '';
  siteCerts = pkgs.writeShellScript "dome-acme-sites" ''
    set -euo pipefail
    install -d -m 0755 ${certLive} ${challengeDir}/.well-known/acme-challenge
    [ -d ${desiredNginx} ] || exit 0
    server=${
      lib.escapeShellArg (
        if cfg.production then
          "https://acme-v02.api.letsencrypt.org/directory"
        else
          "https://acme-staging-v02.api.letsencrypt.org/directory"
      )
    }
    for dns in ${desiredNginx}/*.dns; do
      [ -e "$dns" ] || continue
      name=$(tr -d '\n' < "$dns")
      case "$name" in
        *.dome.ms|dome.ms|_wildcard_.*) continue ;;
      esac
      dest=${certLive}/$name
      if [ -f "$dest/fullchain.pem" ] && [ -f "$dest/key.pem" ]; then
        continue
      fi
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      ${pkgs.lego}/bin/lego --accept-tos \
        --email ${lib.escapeShellArg cfg.email} \
        --http \
        --http.webroot ${challengeDir} \
        --server "$server" \
        --path "$work" \
        --domains "$name" \
        run
      install -d -m 0755 "$dest"
      cp "$work/certificates/$name.crt" "$dest/fullchain.pem"
      cp "$work/certificates/$name.key" "$dest/key.pem"
      chmod 0640 "$dest/key.pem"
      chgrp nginx "$dest/key.pem" 2>/dev/null || true
      rm -rf "$work"
      trap - EXIT
    done
    ${pkgs.systemd}/bin/systemctl start --no-block dome-sync.service || true
  '';
in
{
  config = lib.mkIf (config.dome.enable && cfg.enable) {
    users.users.acme.extraGroups = [ "dome-pki" ];

    systemd.tmpfiles.rules = [
      "d ${challengeDir} 0755 acme nginx -"
      "d ${challengeDir}/.well-known 0755 acme nginx -"
      "d ${challengeDir}/.well-known/acme-challenge 0755 acme nginx -"
      "d /run/dome 0755 root root -"
      "f ${reloadStamp} 0664 acme acme -"
    ];

    systemd.paths.dome-dns-acme-reload = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathModified = reloadStamp;
        Unit = "dome-dns-zone-restart.service";
      };
    };

    systemd.services.dome-dns-zone-restart = {
      description = "Restart dome DNS zone render for ACME TXT updates";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl restart dome-dns-zone.service";
      };
    };

    security.acme = {
      acceptTerms = true;
      defaults = {
        email = cfg.email;
        server = lib.mkIf (!cfg.production) "https://acme-staging-v02.api.letsencrypt.org/directory";
      };
      certs."dome.ms" = {
        domain = "dome.ms";
        extraDomainNames = [ "*.dome.ms" ];
        dnsProvider = "exec";
        environmentFile = execEnv;
        dnsPropagationCheck = false;
        group = "nginx";
        reloadServices = [ "nginx.service" ];
      };
    };

    services.nginx.virtualHosts."_" = {
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
      locations."/.well-known/acme-challenge/" = {
        root = challengeDir;
        extraConfig = "default_type text/plain;";
      };
      locations."/" = {
        return = "404";
      };
    };

    systemd.services."acme-dome.ms" = {
      after = [
        "etcd.service"
        "dome-dns-zone.service"
      ];
      wants = [
        "etcd.service"
        "dome-dns-zone.service"
      ];
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
        lego
        systemd
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = siteCerts;
      };
    };

    systemd.timers.dome-acme-sites = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "15min";
      };
    };

    systemd.paths.dome-acme-challenge-sync = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = [
          challengeDir
          "${challengeDir}/.well-known/acme-challenge"
        ];
        Unit = "dome-acme-challenge-publish.service";
      };
    };

    systemd.services.dome-acme-challenge-publish = {
      description = "Publish HTTP-01 challenge files to etcd";
      after = [ "etcd.service" ];
      path = [
        pkgs.coreutils
        pkgs.etcd
        pkgs.findutils
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "dome-acme-challenge-publish" ''
          set -euo pipefail
          export ETCDCTL_CACERT=${pki}/ca.crt
          export ETCDCTL_CERT=${pki}/node.crt
          export ETCDCTL_KEY=${pki}/node.key
          export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
          if ! etcdctl endpoint health >/dev/null 2>&1; then
            exit 0
          fi
          dir=${challengeDir}/.well-known/acme-challenge
          [ -d "$dir" ] || exit 0
          find "$dir" -type f -print0 | while IFS= read -r -d $'\0' file; do
            rel=''${file#"$dir"/}
            etcdctl put "/dome/acme-challenge/$rel" < "$file" >/dev/null
          done
        '';
      };
    };
  };
}
