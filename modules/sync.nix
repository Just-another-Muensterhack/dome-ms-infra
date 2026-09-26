{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dome.sync;
  pki = config.dome.pki.dir;
  stateRoot = "/var/lib/dome.ms";
  desiredNginx = "${stateRoot}/nginx-desired";
  liveNginx = "${stateRoot}/nginx";
  mediaRoot = "${stateRoot}/data";
  certLive = "/var/lib/dome/certs/live";
  etcdEnv = ''
    export ETCDCTL_CACERT=${pki}/ca.crt
    export ETCDCTL_CERT=${pki}/node.crt
    export ETCDCTL_KEY=${pki}/node.key
    export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
  '';
  maxBytes = 4 * 1024 * 1024;

  syncScript = pkgs.writeShellScript "dome-sync" ''
    set -euo pipefail
    ${etcdEnv}
    etcdctl=${pkgs.etcd}/bin/etcdctl
    install -d -m 0755 ${desiredNginx} ${liveNginx} ${mediaRoot} ${certLive}

    if ! $etcdctl endpoint health >/dev/null 2>&1; then
      echo "etcd unavailable" >&2
      exit 0
    fi

    publish_file() {
      local key=$1
      local file=$2
      local size hash remote
      size=$(wc -c < "$file")
      if [ "$size" -gt ${toString maxBytes} ]; then
        echo "skip $key ($size bytes)" >&2
        return 0
      fi
      hash=$(sha256sum "$file" | cut -d' ' -f1)
      remote=$($etcdctl get "$key.hash" --print-value-only 2>/dev/null || true)
      if [ "$remote" = "$hash" ]; then
        return 0
      fi
      $etcdctl put "$key" < "$file" >/dev/null
      $etcdctl put "$key.hash" "$hash" >/dev/null
    }

    publish_tree() {
      local prefix=$1
      local dir=$2
      [ -d "$dir" ] || return 0
      find "$dir" -type f -print0 | while IFS= read -r -d $'\0' file; do
        rel=''${file#"$dir"/}
        publish_file "$prefix/$rel" "$file"
      done
    }

    pull_tree() {
      local prefix=$1
      local dir=$2
      install -d -m 0755 "$dir"
      $etcdctl get "$prefix/" --prefix --keys-only | while read -r key; do
        case "$key" in
          *.hash|"$prefix"/|"") continue ;;
        esac
        rel=''${key#"$prefix"/}
        dest="$dir/$rel"
        install -d -m 0755 "$(dirname "$dest")"
        $etcdctl get "$key" --print-value-only > "$dest.tmp"
        mv "$dest.tmp" "$dest"
      done
    }

    publish_cert_dir() {
      local cert_dir=$1
      local name issuer file
      name=$(basename "$cert_dir")
      [ -f "$cert_dir/fullchain.pem" ] || return 0
      [ -f "$cert_dir/key.pem" ] || return 0
      issuer=$(${pkgs.openssl}/bin/openssl x509 -in "$cert_dir/fullchain.pem" -noout -issuer 2>/dev/null || true)
      case "$issuer" in
        *[Mm]inica*) return 0 ;;
      esac
      [ -n "$issuer" ] || return 0
      for file in fullchain.pem key.pem chain.pem; do
        [ -f "$cert_dir/$file" ] || continue
        publish_file "/dome/certs/$name/$file" "$cert_dir/$file"
      done
    }

    install_platform_cert() {
      local name=$1
      local src=${certLive}/$name
      local dest=/var/lib/acme/$name
      local issuer
      [ -f "$src/fullchain.pem" ] || return 0
      [ -f "$src/key.pem" ] || return 0
      issuer=$(${pkgs.openssl}/bin/openssl x509 -in "$src/fullchain.pem" -noout -issuer 2>/dev/null || true)
      case "$issuer" in
        *[Mm]inica*) return 0 ;;
      esac
      [ -n "$issuer" ] || return 0
      if [ -f "$dest/fullchain.pem" ]; then
        local have want
        have=$(sha256sum "$dest/fullchain.pem" | cut -d' ' -f1)
        want=$(sha256sum "$src/fullchain.pem" | cut -d' ' -f1)
        [ "$have" = "$want" ] && return 0
      fi
      install -d -m 0750 -o acme -g nginx "$dest"
      cp -f "$src/fullchain.pem" "$dest/fullchain.pem"
      cp -f "$src/key.pem" "$dest/key.pem"
      if [ -f "$src/chain.pem" ]; then
        cp -f "$src/chain.pem" "$dest/chain.pem"
      else
        cp -f "$src/fullchain.pem" "$dest/chain.pem"
      fi
      ln -sfn fullchain.pem "$dest/cert.pem"
      touch "$dest/acme-success"
      chown -R acme:nginx "$dest"
      chmod 0640 "$dest/key.pem"
      chmod 0644 "$dest/fullchain.pem" "$dest/chain.pem"
      systemctl reload nginx.service || true
    }

    publish_tree /dome/nginx ${desiredNginx}
    publish_tree /dome/static ${mediaRoot}

    if [ -d /var/lib/acme ]; then
      for cert_dir in /var/lib/acme/*/; do
        [ -d "$cert_dir" ] || continue
        case "$(basename "$cert_dir")" in
          acme-challenge|http-lego|.lego|.minica) continue ;;
        esac
        publish_cert_dir "$cert_dir"
      done
    fi

    if [ -d ${certLive} ]; then
      for cert_dir in ${certLive}/*/; do
        [ -d "$cert_dir" ] || continue
        publish_cert_dir "$cert_dir"
      done
    fi

    pull_tree /dome/nginx ${desiredNginx}
    pull_tree /dome/static ${mediaRoot}

    $etcdctl get /dome/certs/ --prefix --keys-only | while read -r key; do
      case "$key" in
        *.hash|"") continue ;;
      esac
      rest=''${key#/dome/certs/}
      name=''${rest%%/*}
      file=''${rest#*/}
      [ "$name" != "$rest" ] || continue
      [ -n "$name" ] && [ -n "$file" ] || continue
      dest="${certLive}/$name/$file"
      install -d -m 0755 "$(dirname "$dest")"
      $etcdctl get "$key" --print-value-only > "$dest.tmp"
      mv "$dest.tmp" "$dest"
      if [ "$file" = "key.pem" ]; then
        chmod 0640 "$dest"
        chgrp nginx "$dest" 2>/dev/null || true
      fi
    done

    if [ -d ${certLive} ]; then
      for cert_dir in ${certLive}/*/; do
        [ -d "$cert_dir" ] || continue
        install_platform_cert "$(basename "$cert_dir")"
      done
    fi

    for conf in ${desiredNginx}/*.conf; do
      [ -e "$conf" ] || continue
      base=$(basename "$conf" .conf)
      case "$base" in
        *.dome.ms|dome.ms)
          if [ -f "${certLive}/dome.ms/fullchain.pem" ] || [ -f "${certLive}/$base/fullchain.pem" ]; then
            cp -f "$conf" ${liveNginx}/
          fi
          ;;
        *)
          if [ -f "${certLive}/$base/fullchain.pem" ]; then
            cp -f "$conf" ${liveNginx}/
          fi
          ;;
      esac
    done

    for conf in ${liveNginx}/*.conf; do
      [ -e "$conf" ] || continue
      base=$(basename "$conf" .conf)
      if [ ! -f "${desiredNginx}/$base.conf" ]; then
        rm -f "$conf"
      fi
    done

    systemctl start --no-block dome-nginx-reload.service || true
    systemctl start --no-block dome-dns-zone.service || true
  '';
in
{
  config = lib.mkIf config.dome.enable {
    dome.sync.command = lib.mkDefault syncScript;

    systemd.services.dome-sync = {
      after = [ "etcd.service" ];
      path = with pkgs; [
        coreutils
        etcd
        findutils
        systemd
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${cfg.command}";
      };
    };

    systemd.timers.dome-sync = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.interval;
        OnUnitActiveSec = cfg.interval;
      };
    };

    systemd.services.dome-sync-watch = {
      description = "Watch etcd for dome sync keys";
      wantedBy = [ "multi-user.target" ];
      after = [ "etcd.service" ];
      path = [
        pkgs.etcd
        pkgs.coreutils
        pkgs.systemd
      ];
      serviceConfig = {
        Restart = "always";
        RestartSec = "5s";
      };
      script = ''
        set -euo pipefail
        ${etcdEnv}
        while true; do
          etcdctl watch /dome/ --prefix -- systemctl start --no-block dome-sync.service || sleep 5
        done
      '';
    };
  };
}
