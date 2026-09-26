{
  config,
  lib,
  pkgs,
  fqdn,
  ...
}:
{
  config = lib.mkIf config.dome.enable (
    let
      dir = config.dome.pki.dir;
      secrets = config.sops.secrets;
      caSecret = {
        sopsFile = config.dome.sops.clusterFile;
        mode = "0400";
      };
      dnsSans = lib.concatMapStrings (domain: ",DNS:${domain}") (
        [
          fqdn
          "localhost"
        ]
        ++ config.dome.pki.domains
      );
    in
    {
      sops.secrets = {
        "dome/ca_key" = caSecret;
        "dome/ca_crt" = caSecret;
      };

      users.groups.dome-pki = { };

      dome.discovery.units = [ "dome-pki.service" ];

      systemd.services.dome-pki = {
        wantedBy = [ "multi-user.target" ];
        after = [
          "dome-discovery.service"
          "sops-install-secrets.service"
        ];
        path = with pkgs; [
          coreutils
          openssl
          systemd
        ];
        serviceConfig = {
          Type = "oneshot";
          Restart = "on-failure";
          RestartSec = "30s";
        };
        script = ''
          set -euo pipefail

          if [ ! -s /run/dome/self ]; then
            echo "own address is not listed in /etc/dome/nodes yet" >&2
            exit 1
          fi
          self=$(cat /run/dome/self)

          install -d -m 0755 "$(dirname ${dir})"
          install -d -m 0750 -g dome-pki ${dir}
          install -m 0644 ${secrets."dome/ca_crt".path} ${dir}/ca.crt

          if [ -f ${dir}/node.crt ] \
            && [ "$(cat ${dir}/node.san 2>/dev/null || true)" = "$self" ] \
            && openssl x509 -in ${dir}/node.crt -noout -checkend 2592000 >/dev/null; then
            exit 0
          fi

          work=$(mktemp -d)
          trap 'rm -rf "$work"' EXIT

          printf '%s\n' \
            "subjectAltName=IP:$self,IP:127.0.0.1,IP:::1${dnsSans}" \
            "extendedKeyUsage=serverAuth,clientAuth" \
            "keyUsage=critical,digitalSignature,keyEncipherment" > "$work/ext"

          openssl req -new -nodes \
            -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -subj "/CN=${fqdn}" \
            -keyout "$work/node.key" -out "$work/node.csr"

          openssl x509 -req -in "$work/node.csr" \
            -CA ${secrets."dome/ca_crt".path} -CAkey ${secrets."dome/ca_key".path} \
            -set_serial "0x$(openssl rand -hex 16)" -days 365 \
            -extfile "$work/ext" -out "$work/node.crt"

          install -m 0640 -g dome-pki "$work/node.key" ${dir}/node.key
          install -m 0644 "$work/node.crt" ${dir}/node.crt
          printf '%s\n' "$self" > ${dir}/node.san

          ${lib.optionalString (config.dome.pki.reloadUnits != [ ]) ''
            systemctl try-reload-or-restart --no-block ${lib.escapeShellArgs config.dome.pki.reloadUnits}
          ''}
        '';
      };
    }
  );
}
