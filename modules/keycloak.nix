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
  realmLink = pkgs.writeShellScript "keycloak-realm-link" ''
    set -euo pipefail
    install -d -m 0700 /run/keycloak/data/import
    ln -sfn ${config.sops.templates."msdome.json".path} /run/keycloak/data/import/msdome.json
  '';
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
        "dome-pg-reconcile.service"
        "dome-keycloak-jgroups.service"
        "postgresql-setup.service"
        "dome-pg-app-roles.service"
      ];
      wants = [
        "network-online.target"
        "dome-pg-reconcile.service"
      ];
      requires = [
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
        ExecStartPre = [
          realmLink
          jgroupsStores
        ];
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
