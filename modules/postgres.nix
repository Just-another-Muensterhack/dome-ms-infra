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
          "postgresql-setup.service"
          "dome-pg-app-roles.service"
          "dome-discovery.service"
          "dome-pki.service"
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

          [ -s /etc/dome/nodes ] || exit 0
          pass=$(cat ${passwordFile})
          export PGPASSWORD="$pass"

          sql() {
            local db=$1
            shift
            psql -v ON_ERROR_STOP=1 -d "$db" -tA "$@"
          }

          peer_conn() {
            printf 'host=%s port=5432 dbname=%s user=replicator sslmode=verify-full sslrootcert=%s' "$1" "$2" ${pki}/ca.crt
          }

          peer_sql() {
            local peer=$1
            local db=$2
            shift 2
            psql "$(peer_conn "$peer" "$db")" -v ON_ERROR_STOP=1 -tA "$@"
          }

          table_count() {
            sql "$1" -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'"
          }

          peers=()
          while read -r node _ ipv6; do
            [ "$node" = ${lib.escapeShellArg fqdn} ] && continue
            peers+=("$ipv6")
          done < /etc/dome/nodes

          bootstrap_db() {
            local db=$1
            shift
            [ "$(table_count "$db")" = 0 ] || return 0

            local source=""
            for peer in "''${peers[@]}"; do
              if [ "$(peer_sql "$peer" "$db" -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'" 2>/dev/null || echo 0)" != 0 ]; then
                source=$peer
                break
              fi
            done
            [ -n "$source" ] || return 0

            local owner dump
            owner=$(sql postgres -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$db'")
            dump=$(mktemp)
            pg_dump "$(peer_conn "$source" "$db")" \
              --schema-only --no-owner --no-privileges --no-comments \
              --no-publications --no-subscriptions > "$dump"
            if [ "$#" -gt 0 ]; then
              local tables=()
              for table in "$@"; do
                tables+=(--table "public.$table")
              done
              pg_dump "$(peer_conn "$source" "$db")" \
                --data-only --no-owner --no-privileges "''${tables[@]}" >> "$dump"
            fi
            { printf 'SET ROLE %s;\n' "$owner"; cat "$dump"; } | psql -v ON_ERROR_STOP=1 -q -d "$db"
            rm -f "$dump"
            echo "bootstrapped $db schema from $source"
          }

          local_empty() {
            local db=$1
            for table in $(sql "$db" -c "SELECT format('%I.%I', schemaname, tablename) FROM pg_publication_tables WHERE pubname = 'cluster_pub'"); do
              [ -z "$(sql "$db" -c "SELECT 1 FROM $table LIMIT 1")" ] || return 1
            done
          }

          own_sub() {
            sql "$1" -c "SELECT subname FROM pg_subscription WHERE subdbid = (SELECT oid FROM pg_database WHERE datname = current_database()) $2"
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
            local skip=" $* "

            local tables=()
            for table in $(sql "$db" -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename"); do
              case "$skip" in
                *" $table "*) ;;
                *) tables+=("public.\"$table\"") ;;
              esac
            done

            local statements=""
            if [ "$(sql "$db" -c "SELECT count(*) FROM pg_publication WHERE pubname = 'cluster_pub' AND puballtables")" != 0 ]; then
              statements="DROP PUBLICATION cluster_pub;"
            fi
            if [ -n "$statements" ] || [ "$(sql "$db" -c "SELECT count(*) FROM pg_publication WHERE pubname = 'cluster_pub'")" = 0 ]; then
              statements="$statements CREATE PUBLICATION cluster_pub WITH (publish = 'insert, update, delete', publish_generated_columns = stored);"
            fi
            statements="$statements ALTER PUBLICATION cluster_pub SET (publish = 'insert, update, delete');"
            if [ "''${#tables[@]}" -gt 0 ]; then
              statements="$statements ALTER PUBLICATION cluster_pub SET TABLE $(IFS=,; echo "''${tables[*]}");"
            fi
            sql "$db" -c "$statements"

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
              skip = lib.escapeShellArgs (skipTables.${db} or [ ]);
            in
            ''
              bootstrap_db ${db} ${skip}
              setup_db ${db} ${skip}
            ''
          ) appDbs}

          wanted=" "
          created=()
          for peer in "''${peers[@]}"; do
            for db in ${lib.escapeShellArgs appDbs}; do
              sub="sub_$(printf '%s_%s' "$db" "$peer" | tr '.:' '__')"
              wanted="$wanted$sub "

              pg_isready -q -h "$peer" -U replicator || continue
              peer_sql "$peer" "$db" -c "SELECT 1" > /dev/null 2>&1 || continue

              if [ -z "$(own_sub "$db" "AND subname = '$sub'")" ]; then
                [ "$(table_count "$db")" != 0 ] || continue
                copy=false
                if local_empty "$db"; then
                  copy=true
                fi
                sql "$db" -v conn="$(peer_conn "$peer" "$db") password=$pass" <<SQL
          CREATE SUBSCRIPTION $sub CONNECTION :'conn' PUBLICATION cluster_pub WITH (copy_data = $copy, origin = none, streaming = parallel);
          SQL
                created+=("$db:$sub")
              else
                sql "$db" -c "ALTER SUBSCRIPTION $sub REFRESH PUBLICATION WITH (copy_data = false);"
              fi
            done
          done

          for entry in "''${created[@]}"; do
            db=''${entry%%:*}
            sub=''${entry#*:}
            for _ in $(seq 1 180); do
              pending=$(sql "$db" -c "SELECT count(*) FROM pg_subscription_rel r JOIN pg_subscription s ON s.oid = r.srsubid WHERE s.subname = '$sub' AND r.srsubstate NOT IN ('r', 's')")
              [ "$pending" = 0 ] && break
              sleep 1
            done
          done

          for db in ${lib.escapeShellArgs appDbs}; do
            for sub in $(own_sub "$db" "AND subname LIKE 'sub\_%'"); do
              case "$wanted" in
                *" $sub "*) ;;
                *)
                  sql "$db" -c "DROP SUBSCRIPTION $sub;" || sql "$db" <<SQL
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
