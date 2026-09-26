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
      cfg = config.services.etcd;
      pki = config.dome.pki.dir;
      envFile = "/run/dome/etcd.env";
      etcdctl = "${cfg.package}/bin/etcdctl --cacert ${pki}/ca.crt --cert ${pki}/node.crt --key ${pki}/node.key";
    in
    {
      dome = {
        discovery.units = [ "etcd.service" ];
        pki.reloadUnits = [ "etcd.service" ];
        firewall.peerTCPPorts = [
          2379
          2380
        ];
      };

      users.users.etcd.extraGroups = [ "dome-pki" ];

      services.etcd = {
        enable = true;
        name = fqdn;
        listenClientUrls = [ "https://[::]:2379" ];
        listenPeerUrls = [ "https://[::]:2380" ];
        certFile = "${pki}/node.crt";
        keyFile = "${pki}/node.key";
        trustedCaFile = "${pki}/ca.crt";
        clientCertAuth = true;
        peerClientCertAuth = true;
        initialClusterToken = "dome";
      };

      systemd.services.dome-etcd-prepare = {
        after = [
          "dome-discovery.service"
          "dome-pki.service"
        ];
        requires = [ "dome-pki.service" ];
        path = with pkgs; [
          coreutils
          gawk
          gnugrep
          util-linux
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = "10min";
        };
        script = ''
          set -euo pipefail

          url() {
            case "$1" in
              *:*) printf 'https://[%s]:%s' "$1" "$2" ;;
              *) printf 'https://%s:%s' "$1" "$2" ;;
            esac
          }

          shuffle_peers() {
            grep -vxF "$self" /run/dome/peers | shuf || true
          }

          for _attempt in $(seq 1 120); do
            if [ ! -s /run/dome/self ]; then
              echo "own address is not listed in /etc/dome/nodes yet" >&2
              sleep 5
              continue
            fi
            self=$(cat /run/dome/self)
            peer_url=$(url "$self" 2380)

            install -d -m 0755 /run/dome
            printf '%s\n' \
              "ETCD_ADVERTISE_CLIENT_URLS=$(url "$self" 2379)" \
              "ETCD_INITIAL_ADVERTISE_PEER_URLS=$peer_url" > ${envFile}

            if [ -d ${cfg.dataDir}/member ]; then
              exit 0
            fi

            joined=0
            for peer in $(shuffle_peers); do
              endpoint=$(url "$peer" 2379)
              ${etcdctl} --endpoints "$endpoint" endpoint health >/dev/null 2>&1 || continue

              stale=$(${etcdctl} --endpoints "$endpoint" member list | awk -F', ' -v u="$peer_url" '$4 == u { print $1 }')
              if [ -n "$stale" ]; then
                ${etcdctl} --endpoints "$endpoint" member remove "$stale"
              fi

              ${etcdctl} --endpoints "$endpoint" member add ${fqdn} --peer-urls "$peer_url" \
                | grep '^ETCD_INITIAL_CLUSTER=' >> ${envFile}
              printf '%s\n' "ETCD_INITIAL_CLUSTER_STATE=existing" >> ${envFile}
              joined=1
              break
            done
            if [ "$joined" = 1 ]; then
              exit 0
            fi

            delay=$(( (RANDOM % 30) + 5 ))
            echo "no healthy etcd peer; waiting ''${delay}s before considering bootstrap" >&2
            sleep "$delay"

            still_alone=1
            for peer in $(shuffle_peers); do
              endpoint=$(url "$peer" 2379)
              if ${etcdctl} --endpoints "$endpoint" endpoint health >/dev/null 2>&1; then
                still_alone=0
                break
              fi
            done
            if [ "$still_alone" = 1 ]; then
              printf '%s\n' \
                "ETCD_INITIAL_CLUSTER=${fqdn}=$peer_url" \
                "ETCD_INITIAL_CLUSTER_STATE=new" >> ${envFile}
              exit 0
            fi
          done

          echo "gave up waiting for etcd peers" >&2
          exit 1
        '';
      };

      systemd.services.etcd = {
        after = [
          "dome-pki.service"
          "dome-etcd-prepare.service"
        ];
        requires = [
          "dome-pki.service"
          "dome-etcd-prepare.service"
        ];
        serviceConfig.EnvironmentFile = envFile;
        serviceConfig.Environment = [ "ETCD_MAX_REQUEST_BYTES=4194304" ];
      };
    }
  );
}
