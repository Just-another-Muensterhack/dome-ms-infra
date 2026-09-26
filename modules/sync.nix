{ config, lib, ... }:
let
  cfg = config.dome.sync;
in
{
  config = lib.mkIf (config.dome.enable && cfg.command != null) {
    systemd.services.dome-sync = {
      after = [
        "etcd.service"
        "postgresql.service"
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
  };
}
