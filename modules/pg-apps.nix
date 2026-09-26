{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf (config.dome.enable && config.dome.apps.enable) {
    sops.secrets = {
      "keycloak/db_password" = {
        sopsFile = config.dome.sops.clusterFile;
        restartUnits = [
          "dome-pg-app-roles.service"
          "keycloak.service"
        ];
      };
      "postgres/dome_password" = {
        sopsFile = config.dome.sops.clusterFile;
        restartUnits = [
          "dome-pg-app-roles.service"
          "dome-backend.service"
        ];
      };
    };

    services.postgresql = {
      ensureDatabases = [
        "keycloak"
        "dome"
      ];
      ensureUsers = [
        {
          name = "keycloak";
          ensureDBOwnership = true;
        }
        {
          name = "dome";
          ensureDBOwnership = true;
        }
      ];
      authentication = lib.mkAfter ''
        host  keycloak  keycloak  127.0.0.1/32  scram-sha-256
        host  keycloak  keycloak  ::1/128       scram-sha-256
        host  dome      dome      127.0.0.1/32  scram-sha-256
        host  dome      dome      ::1/128       scram-sha-256
      '';
    };

    systemd.services.dome-pg-app-roles = {
      description = "Set passwords for dome.ms application database roles";
      after = [ "postgresql-setup.service" ];
      requires = [ "postgresql-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        config.services.postgresql.package
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        Group = "postgres";
        LoadCredential = [
          "kc:${config.sops.secrets."keycloak/db_password".path}"
          "dome:${config.sops.secrets."postgres/dome_password".path}"
        ];
      };
      script = ''
        set -euo pipefail
        kc_pass=$(cat "$CREDENTIALS_DIRECTORY/kc")
        dome_pass=$(cat "$CREDENTIALS_DIRECTORY/dome")
        psql -v ON_ERROR_STOP=1 -v kc="$kc_pass" -v dome="$dome_pass" <<'SQL'
        ALTER ROLE keycloak WITH LOGIN PASSWORD :'kc';
        ALTER ROLE dome WITH LOGIN PASSWORD :'dome';
        SQL
      '';
    };
  };
}
