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
      pg = config.services.postgresql.package;
      oldPg = pkgs.postgresql_16;
      pki = config.dome.pki.dir;
      passwordFile = config.sops.secrets."postgres/replicator_password".path;
      node = config.dome.nodes.${fqdn} or null;
      sequenceOffset = if node != null then node.sequenceOffset else 1;
      appDbs = lib.optionals config.dome.apps.enable [
        "keycloak"
        "dome"
      ];
      skipTables = {
        keycloak = [
          "databasechangelog"
          "databasechangeloglock"
        ];
        dome = [ "django_migrations" ];
      };
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
        package = pkgs.postgresql_18;
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

      systemd.services.dome-pg-upgrade = {
        description = "Upgrade Postgres data directory from 16 to 18 when needed";
        wantedBy = [ "postgresql.service" ];
        before = [ "postgresql.service" ];
        after = [ "dome-pki.service" ];
        unitConfig.ConditionPathExists = "/var/lib/postgresql/16";
        path = [
          oldPg
          pg
          pkgs.coreutils
          pkgs.util-linux
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "postgres";
          Group = "postgres";
        };
        script = ''
          set -euo pipefail
          newdir=/var/lib/postgresql/18
          if [ -d "$newdir/base" ]; then
            exit 0
          fi
          install -d -m 0700 "$newdir"
          ${oldPg}/bin/pg_ctl -D /var/lib/postgresql/16 -m fast stop || true
          ${pg}/bin/initdb -D "$newdir"
          ${pg}/bin/pg_upgrade \
            --old-datadir /var/lib/postgresql/16 \
            --new-datadir "$newdir" \
            --old-bindir ${oldPg}/bin \
            --new-bindir ${pg}/bin \
            --link
        '';
      };

      systemd.services.postgresql = {
        after = [
          "dome-pki.service"
          "dome-pg-upgrade.service"
        ];
        requires = [ "dome-pki.service" ];
        wants = [ "dome-pg-upgrade.service" ];
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
            local db=$1
            shift
            psql -v ON_ERROR_STOP=1 -d "$db" -tA "$@"
          }

          setup_role() {
            psql -v ON_ERROR_STOP=1 -v pass="$pass" <<'SQL'
          SELECT 'CREATE ROLE replicator WITH REPLICATION LOGIN'
            WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') \gexec
          ALTER ROLE replicator WITH PASSWORD :'pass';
          GRANT pg_read_all_data TO replicator;
          SQL
          }

          setup_db() {
            local db=$1
            shift
            local skip=("$@")

            sql "$db" <<SQL
          SELECT 'CREATE PUBLICATION cluster_pub FOR ALL TABLES WITH (publish_generated_columns = stored)'
            WHERE NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'cluster_pub') \gexec
          SQL

            for table in "''${skip[@]}"; do
              sql "$db" -c "ALTER PUBLICATION cluster_pub DROP TABLE IF EXISTS $table;" || true
            done

            sql "$db" <<SQL
          DO \$\$
          DECLARE
            seq text;
            last_val bigint;
            called boolean;
            target bigint;
          BEGIN
            FOR seq IN
              SELECT quote_ident(n.nspname) || '.' || quote_ident(c.relname)
              FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE c.relkind = 'S' AND n.nspname NOT IN ('pg_catalog', 'information_schema')
            LOOP
              EXECUTE format('ALTER SEQUENCE %s INCREMENT BY 1000', seq);
              EXECUTE format('SELECT last_value, is_called FROM %s', seq) INTO last_val, called;
              IF NOT called THEN
                EXECUTE format('SELECT setval(%L, %s, false)', seq, ${toString sequenceOffset});
              ELSIF last_val % 1000 <> ${toString sequenceOffset} THEN
                target := last_val - (last_val % 1000) + ${toString sequenceOffset};
                IF target <= last_val THEN
                  target := target + 1000;
                END IF;
                EXECUTE format('SELECT setval(%L, %s, true)', seq, target);
              END IF;
            END LOOP;
          END
          \$\$;
          SQL
          }

          setup_role
          ${lib.concatMapStrings (
            db:
            let
              skip = skipTables.${db} or [ ];
            in
            ''
              setup_db ${db} ${lib.escapeShellArgs skip}
            ''
          ) appDbs}

          wanted=" "
          while read -r peer; do
            [ "$peer" = "$self" ] && continue
            for db in ${lib.escapeShellArgs appDbs}; do
              sub="sub_$(printf '%s_%s' "$db" "$peer" | tr '.:' '__')"
              wanted="$wanted$sub "

              pg_isready -q -h "$peer" -U replicator || continue

              if [ -z "$(sql "$db" -c "SELECT 1 FROM pg_subscription WHERE subname = '$sub'")" ]; then
                for table in $(sql "$db" -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public'"); do
                  case " $(sql "$db" -c "SELECT tablename FROM pg_publication_tables WHERE pubname = 'cluster_pub'" | tr '\n' ' ') " in
                    *" $table "*) sql "$db" -c "TRUNCATE TABLE \"$table\" CASCADE;" || true ;;
                  esac
                done
                sql "$db" -v conn="host=$peer port=5432 dbname=$db user=replicator password=$pass sslmode=verify-full sslrootcert=${pki}/ca.crt" <<SQL
          CREATE SUBSCRIPTION $sub CONNECTION :'conn' PUBLICATION cluster_pub WITH (copy_data = true, origin = none, streaming = parallel);
          SQL
              else
                sql "$db" -c "ALTER SUBSCRIPTION $sub REFRESH PUBLICATION WITH (copy_data = true);"
              fi
            done
          done < /run/dome/peers

          for db in ${lib.escapeShellArgs appDbs}; do
            for sub in $(sql "$db" -c "SELECT subname FROM pg_subscription WHERE subname LIKE 'sub\_%'"); do
              case "$wanted" in
                *" $sub "*) ;;
                *)
                  sql "$db" <<SQL
          ALTER SUBSCRIPTION $sub DISABLE;
          ALTER SUBSCRIPTION $sub SET (slot_name = NONE);
          DROP SUBSCRIPTION $sub;
          SQL
                  ;;
              esac
            done
          done
        '';
      };
    }
  );
}
