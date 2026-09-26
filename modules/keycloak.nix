{
  config,
  lib,
  pkgs,
  inputs,
  fqdn,
  ...
}:
let
  cfg = config.dome.apps;
  http = import ./apps/http.nix { inherit config lib; };
  realm = import ./keycloak/realm.nix {
    webHost = cfg.web.host;
    publicHost = cfg.publicHost;
    clientSecret = config.sops.placeholder."keycloak/client_secret";
  };
  node = config.dome.nodes.${fqdn} or null;
  pki = config.dome.pki.dir;
  jgroupsDir = "/var/lib/dome/keycloak-jgroups";
  jgroupsEnv = "${jgroupsDir}/jgroups.env";
  jgroupsPort = 7800;
  jgroupsFdPort = 57800;
  jgroupsStores = pkgs.writeShellScript "keycloak-jgroups-stores" ''
    set -euo pipefail
    umask 077
    dir=/run/keycloak/jgroups
    ${pkgs.coreutils}/bin/install -d -m 0700 "$dir"
    pass=$(${pkgs.coreutils}/bin/mktemp -p "$dir")
    trap '${pkgs.coreutils}/bin/rm -f "$pass"' EXIT
    printf '%s' "$KC_CACHE_EMBEDDED_MTLS_KEY_STORE_PASSWORD" > "$pass"
    ${pkgs.openssl}/bin/openssl pkcs12 -export \
      -in ${pki}/node.crt \
      -inkey ${pki}/node.key \
      -out "$dir/keystore.p12" \
      -passout "file:$pass"
    ${pkgs.openssl}/bin/openssl pkcs12 -export -nokeys \
      -in ${pki}/ca.crt \
      -out "$dir/truststore.p12" \
      -passout "file:$pass"
  '';
  initialHosts = lib.concatMapStringsSep "," (peer: "${peer.ipv4}[${toString jgroupsPort}]") (
    lib.attrValues config.dome.nodes
  );
  pg = config.services.postgresql.package;
  adoptChangelog = pkgs.writeShellScript "keycloak-adopt-changelog" ''
    set -euo pipefail
    kc_pass=$(cat "$CREDENTIALS_DIRECTORY/kc")
    rep_pass=$(cat "$CREDENTIALS_DIRECTORY/rep")

    local_sql() {
      PGPASSWORD="$kc_pass" ${pg}/bin/psql \
        -h 127.0.0.1 -U keycloak -d keycloak -v ON_ERROR_STOP=1 -tA "$@"
    }

    if [ "$(local_sql -c "SELECT to_regclass('public.client') IS NOT NULL")" != t ]; then
      exit 0
    fi

    recorded=$(local_sql -c "SELECT CASE WHEN to_regclass('public.databasechangelog') IS NULL THEN 0 ELSE (SELECT count(*) FROM public.databasechangelog WHERE id = '1.0.0.Final-KEYCLOAK-5461') END")
    if [ "$recorded" != 0 ]; then
      exit 0
    fi

    if [ ! -s /run/dome/peers ]; then
      echo "keycloak schema is present but databasechangelog is not, and no peers are listed" >&2
      exit 1
    fi

    dump=$(mktemp)
    trap 'rm -f "$dump"' EXIT
    adopted=0
    while read -r peer; do
      [ -n "$peer" ] || continue
      PGPASSWORD="$rep_pass" ${pg}/bin/pg_isready -q -h "$peer" -p 5432 -U replicator || continue
      count=$(PGPASSWORD="$rep_pass" ${pg}/bin/psql \
        "host=$peer port=5432 dbname=keycloak user=replicator sslmode=verify-full sslrootcert=${pki}/ca.crt" \
        -v ON_ERROR_STOP=1 -tA \
        -c "SELECT count(*) FROM public.databasechangelog WHERE id = '1.0.0.Final-KEYCLOAK-5461'" \
        2>/dev/null || true)
      if [ "$count" != 1 ]; then
        continue
      fi
      PGPASSWORD="$rep_pass" ${pg}/bin/pg_dump \
        "host=$peer port=5432 dbname=keycloak user=replicator sslmode=verify-full sslrootcert=${pki}/ca.crt" \
        --no-owner --no-privileges \
        -t public.databasechangelog \
        -t public.databasechangeloglock \
        > "$dump"
      adopted=1
      break
    done < /run/dome/peers

    if [ "$adopted" != 1 ]; then
      echo "keycloak schema is present but no peer has databasechangelog" >&2
      exit 1
    fi

    local_sql -c "DROP TABLE IF EXISTS public.databasechangeloglock, public.databasechangelog;"
    PGPASSWORD="$kc_pass" ${pg}/bin/psql \
      -h 127.0.0.1 -U keycloak -d keycloak -v ON_ERROR_STOP=1 -f "$dump"
    local_sql -c "UPDATE public.databasechangeloglock SET locked = false, lockgranted = NULL, lockedby = NULL;"
    echo "adopted keycloak databasechangelog from a peer"
  '';
  cacheConfig = pkgs.writeText "keycloak-cache.xml" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <infinispan
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
            xsi:schemaLocation="urn:infinispan:config:16.0 https://infinispan.org/schemas/infinispan-config-16.0.xsd"
            xmlns="urn:infinispan:config:16.0">
        <jgroups>
            <stack name="tcpping" extends="tcp">
                <TCPPING initial_hosts="${initialHosts}"
                         port_range="0"
                         stack.combine="REPLACE"
                         stack.position="MPING"/>
            </stack>
        </jgroups>
        <cache-container name="keycloak">
            <transport lock-timeout="60000" stack="tcpping"/>
        </cache-container>
    </infinispan>
  '';
in
{
  config = lib.mkIf (config.dome.enable && cfg.enable) {
    assertions = [
      {
        assertion = node != null;
        message = "${fqdn} must be listed in dome.nodes so Keycloak can join the cluster";
      }
    ];

    dome.firewall.peerTCPPorts = [
      jgroupsPort
      jgroupsFdPort
    ];

    dome.pki = {
      domains = [
        cfg.web.host
        cfg.backend.host
        cfg.keycloak.host
      ];
      reloadUnits = [
        "nginx.service"
        "keycloak.service"
      ];
    };

    sops.secrets."keycloak/admin_password" = {
      sopsFile = config.dome.sops.clusterFile;
    };

    sops.templates."keycloak-bootstrap.env" = {
      content = ''
        KC_BOOTSTRAP_ADMIN_USERNAME=admin
        KC_BOOTSTRAP_ADMIN_PASSWORD=${config.sops.placeholder."keycloak/admin_password"}
      '';
    };

    sops.templates."msdome.json" = {
      content = builtins.toJSON realm;
      mode = "0444";
    };

    services.keycloak = {
      enable = true;
      database = {
        type = "postgresql";
        createLocally = false;
        host = "localhost";
        port = 5432;
        name = "keycloak";
        username = "keycloak";
        passwordFile = config.sops.secrets."keycloak/db_password".path;
        useSSL = false;
      };
      realmFiles = [ config.sops.templates."msdome.json".path ];
      themes.dome = import ./keycloak/theme.nix { inherit pkgs inputs; };
      settings = {
        hostname = "https://${cfg.keycloak.host}";
        hostname-strict = false;
        hostname-backchannel-dynamic = true;
        http-enabled = true;
        http-port = cfg.keycloak.port;
        health-enabled = true;
        proxy-headers = "xforwarded";
        cache = "ispn";
        cache-config-file = "${cacheConfig}";
        cache-embedded-network-bind-address = if node == null then "127.0.0.1" else node.ipv4;
        cache-embedded-network-bind-port = jgroupsPort;
      };
    };

    systemd.services.dome-keycloak-changelog = {
      description = "Adopt Keycloak Liquibase history for a replicated schema";
      after = [
        "postgresql.service"
        "dome-pg-app-roles.service"
        "dome-discovery.service"
        "dome-pki.service"
      ];
      requires = [
        "postgresql.service"
        "dome-pg-app-roles.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        LoadCredential = [
          "kc:${config.sops.secrets."keycloak/db_password".path}"
          "rep:${config.sops.secrets."postgres/replicator_password".path}"
        ];
      };
      path = [ pkgs.coreutils ];
      script = "${adoptChangelog}";
    };

    systemd.services.dome-keycloak-jgroups = {
      description = "Keycloak cluster transport password";
      wantedBy = [ "multi-user.target" ];
      before = [ "keycloak.service" ];
      path = [
        pkgs.coreutils
        pkgs.openssl
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        install -d -m 0700 ${jgroupsDir}
        if [ -s ${jgroupsEnv} ]; then
          exit 0
        fi
        pass=$(openssl rand -hex 32)
        umask 077
        cat > ${jgroupsEnv} <<EOF
        KC_CACHE_EMBEDDED_MTLS_ENABLED=true
        KC_CACHE_EMBEDDED_MTLS_KEY_STORE_FILE=/run/keycloak/jgroups/keystore.p12
        KC_CACHE_EMBEDDED_MTLS_TRUST_STORE_FILE=/run/keycloak/jgroups/truststore.p12
        KC_CACHE_EMBEDDED_MTLS_KEY_STORE_PASSWORD=$pass
        KC_CACHE_EMBEDDED_MTLS_TRUST_STORE_PASSWORD=$pass
        EOF
        chmod 0400 ${jgroupsEnv}
      '';
    };

    systemd.services.keycloak = {
      after = [
        "network-online.target"
        "dome-discovery.service"
        "dome-pki.service"
        "dome-keycloak-changelog.service"
        "dome-keycloak-jgroups.service"
        "postgresql-setup.service"
        "dome-pg-app-roles.service"
      ];
      wants = [ "network-online.target" ];
      requires = [
        "dome-keycloak-changelog.service"
        "dome-keycloak-jgroups.service"
        "postgresql-setup.service"
        "dome-pg-app-roles.service"
      ];
      serviceConfig = {
        SupplementaryGroups = [ "dome-pki" ];
        EnvironmentFile = [
          config.sops.templates."keycloak-bootstrap.env".path
          jgroupsEnv
        ];
        ExecStartPre = [ jgroupsStores ];
      };
    };

    services.nginx = {
      enable = true;
      virtualHosts.${cfg.keycloak.host} = http.tls // {
        locations."/" = http.proxy cfg.keycloak.port;
      };
    };

    users.users.nginx.extraGroups = [ "dome-pki" ];

    systemd.services.nginx = lib.mkIf (!config.dome.acme.enable) {
      after = [ "dome-pki.service" ];
      requires = [ "dome-pki.service" ];
    };
  };
}
