{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dome.discovery;
in
{
  config = lib.mkIf config.dome.enable {
    systemd.services.dome-discovery = {
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "nftables.service"
      ];
      path = with pkgs; [
        coreutils
        gawk
        getent
        gnugrep
        iproute2
        nftables
        systemd
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        install -d -m 0755 /run/dome

        resolved=$(getent ahosts ${lib.escapeShellArg cfg.name} | awk '{ print $1 }' | sort -u || true)
        if [ -n "$resolved" ]; then
          printf '%s\n' "$resolved" > /run/dome/peers.tmp
          mv /run/dome/peers.tmp /run/dome/peers
        else
          echo "no addresses resolved for ${cfg.name}, keeping previous peers" >&2
        fi

        [ -s /run/dome/peers ] || exit 0

        local_addrs=$(ip -o addr show scope global | awk '{ split($4, a, "/"); print a[1] }' | sort -u)
        self=$(comm -12 /run/dome/peers <(printf '%s\n' "$local_addrs") | head -n 1 || true)
        if [ -n "$self" ]; then
          printf '%s\n' "$self" > /run/dome/self
        fi

        v4=$(grep -v ':' /run/dome/peers | paste -sd, - || true)
        v6=$(grep ':' /run/dome/peers | paste -sd, - || true)
        nft flush set inet dome peers4
        nft flush set inet dome peers6
        [ -z "$v4" ] || nft add element inet dome peers4 "{ $v4 }"
        [ -z "$v6" ] || nft add element inet dome peers6 "{ $v6 }"

        ${lib.optionalString (cfg.units != [ ]) ''
          systemctl start --no-block ${lib.escapeShellArgs cfg.units}
        ''}
      '';
    };

    systemd.timers.dome-discovery = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = cfg.interval;
      };
    };
  };
}
