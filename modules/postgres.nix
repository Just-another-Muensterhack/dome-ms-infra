{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf config.dome.enable (
    let
      pg = config.services.postgresql.package;
      pki = config.dome.pki.dir;
      passwordFile = config.sops.secrets."postgres/replicator_password".path;
    in
    {
      dome = {
        discovery.units = [ "dome-pg-reconcile.service" ];
        pki.reloadUnits = [ "postgresql.service" ];
        firewall.peerTCPPorts = [ 5432 ];
      };

      sops.secrets."postgres/replicator_password" = {
        sopsFile = config.dome.sops.clusterFile;
        owner = "postgres";
        group = "postgres";
      };

      users.users.postgres.extraGroups = [ "dome-pki" ];

      services.postgresql = {
        enable = true;
        package = pkgs.postgresql_16;
        enableTCPIP = true;
        settings = {
          wal_level = "logical";
          ssl = true;
          ssl_cert_file = "${pki}/node.crt";
          ssl_key_file = "${pki}/node.key";
          ssl_ca_file = "${pki}/ca.crt";
        };
        authentication = lib.mkOverride 10 ''
          local   all  all                      peer
          host    all  all         127.0.0.1/32 scram-sha-256
          host    all  all         ::1/128      scram-sha-256
          hostssl all  replicator  0.0.0.0/0    scram-sha-256
          hostssl all  replicator  ::/0         scram-sha-256
        '';
      };

      systemd.services.postgresql = {
        after = [ "dome-pki.service" ];
        requires = [ "dome-pki.service" ];
      };

      systemd.services.dome-pg-reconcile = {
        after = [
          "postgresql.service"
          "dome-discovery.service"
        ];
        requires = [ "postgresql.service" ];
        path = [
          pg
          pkgs.coreutils
        ];
        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          Group = "postgres";
        };
        script = ''
          set -euo pipefail

          [ -s /run/dome/self ] || exit 0
          [ -s /run/dome/peers ] || exit 0
          self=$(cat /run/dome/self)
          pass=$(cat ${passwordFile})

          sql() {
            psql -v ON_ERROR_STOP=1 -tA "$@"
          }

          sql -v pass="$pass" <<'SQL'
          SELECT 'CREATE ROLE replicator WITH REPLICATION LOGIN'
            WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') \gexec
          ALTER ROLE replicator WITH PASSWORD :'pass';
          GRANT pg_read_all_data TO replicator;
          SELECT 'CREATE PUBLICATION cluster_pub FOR ALL TABLES'
            WHERE NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'cluster_pub') \gexec
          SQL

          wanted=" "
          while read -r peer; do
            [ "$peer" = "$self" ] && continue
            sub="sub_$(printf '%s' "$peer" | tr '.:' '__')"
            wanted="$wanted$sub "

            pg_isready -q -h "$peer" -U replicator || continue

            if [ -z "$(sql -c "SELECT 1 FROM pg_subscription WHERE subname = '$sub'")" ]; then
              sql -v conn="host=$peer port=5432 dbname=postgres user=replicator password=$pass sslmode=verify-full sslrootcert=${pki}/ca.crt" <<SQL
          CREATE SUBSCRIPTION $sub CONNECTION :'conn' PUBLICATION cluster_pub WITH (copy_data = true, origin = none);
          SQL
            else
              sql -c "ALTER SUBSCRIPTION $sub REFRESH PUBLICATION WITH (copy_data = true);"
            fi
          done < /run/dome/peers

          for sub in $(sql -c "SELECT subname FROM pg_subscription WHERE subname LIKE 'sub\_%'"); do
            case "$wanted" in
              *" $sub "*) ;;
              *)
                sql <<SQL
          ALTER SUBSCRIPTION $sub DISABLE;
          ALTER SUBSCRIPTION $sub SET (slot_name = NONE);
          DROP SUBSCRIPTION $sub;
          SQL
                ;;
            esac
          done
        '';
      };
    }
  );
}
