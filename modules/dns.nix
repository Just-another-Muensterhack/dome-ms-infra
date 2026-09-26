{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dome;
  nodes = lib.attrValues cfg.nodes;
  pki = config.dome.pki.dir;
  zoneDir = "/var/lib/dome/dns";
  zoneFile = "${zoneDir}/dome.ms.zone";
  etcdEnv = ''
    export ETCDCTL_CACERT=${pki}/ca.crt
    export ETCDCTL_CERT=${pki}/node.crt
    export ETCDCTL_KEY=${pki}/node.key
    export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
  '';

  platformHosts = lib.optionals cfg.apps.enable [
    cfg.apps.web.host
    cfg.apps.backend.host
    cfg.apps.keycloak.host
  ];

  sharedNames = [
    "nodes.dome.ms"
    "ns.dome.ms"
    "dns.dome.ms"
    "acme.dome.ms"
    "status.dome.ms"
  ];

  rrBlock =
    name:
    lib.concatMapStrings (node: ''
      ${name}. 60 IN A ${node.ipv4}
      ${name}. 60 IN AAAA ${node.ipv6}
    '') nodes;

  staticZone = pkgs.writeText "dome.ms.static.zone" ''
    $ORIGIN dome.ms.
    $TTL 60
    @ 60 IN SOA ns.dome.ms. hostmaster.dome.ms. (
      SERIAL
      3600
      600
      604800
      60
    )
    @ 60 IN NS ns.dome.ms.
    @ 60 IN NS dns.dome.ms.
    ${rrBlock "dome.ms"}
    ${lib.concatMapStrings rrBlock (sharedNames ++ platformHosts)}
    ${lib.concatMapStrings (node: rrBlock node.fqdn) nodes}
  '';

  renderZone = pkgs.writeShellScript "dome-dns-zone" ''
    set -euo pipefail
    ${etcdEnv}
    install -d -m 0755 ${zoneDir}
    serial=1
    dynamic=$(mktemp)
    trap 'rm -f "$dynamic"' EXIT

    if ${pkgs.etcd}/bin/etcdctl endpoint health >/dev/null 2>&1; then
      serial=$(${pkgs.etcd}/bin/etcdctl get /dome/dns/ --prefix --write-out=json \
        | ${pkgs.jq}/bin/jq -r '.header.revision // 1')
      ${pkgs.etcd}/bin/etcdctl get /dome/dns/ --prefix --write-out=simple \
        | ${pkgs.gawk}/bin/awk '
            /^\/dome\/dns\// {
              key=$0
              sub(/^\/dome\/dns\//, "", key)
              sub(/\.$/, "", key)
              getline
              gsub(/"/, "\\\"")
              print key ". 60 IN TXT \"" $0 "\""
            }
          ' >> "$dynamic" || true

      for name in $(${pkgs.etcd}/bin/etcdctl get /dome/nginx/ --prefix --keys-only \
        | ${pkgs.gnused}/bin/sed 's|^/dome/nginx/||; s|\.conf$||'); do
        case "$name" in
          *.dome.ms|dome.ms)
            ${lib.concatMapStrings (node: ''
              printf '%s. 60 IN A %s\n' "$name" ${lib.escapeShellArg node.ipv4} >> "$dynamic"
              printf '%s. 60 IN AAAA %s\n' "$name" ${lib.escapeShellArg node.ipv6} >> "$dynamic"
            '') nodes}
            ;;
        esac
      done
    fi

    ${pkgs.gnused}/bin/sed "s/SERIAL/$serial/" ${staticZone} > ${zoneFile}.tmp
    cat "$dynamic" >> ${zoneFile}.tmp
    mv ${zoneFile}.tmp ${zoneFile}
    chown knot:knot ${zoneFile}
    ${pkgs.systemd}/bin/systemctl try-reload-or-restart knot.service || true
  '';
in
{
  config = lib.mkIf cfg.enable {
    networking.firewall.allowedUDPPorts = [ 53 ];
    networking.firewall.allowedTCPPorts = [ 53 ];

    users.users.knot.extraGroups = [ "dome-pki" ];

    services.knot = {
      enable = true;
      settings = {
        server.listen = [
          "0.0.0.0@53"
          "::@53"
        ];
        log.syslog.any = "info";
        zone."dome.ms" = {
          file = "dome.ms.zone";
          storage = zoneDir;
        };
      };
    };

    systemd.tmpfiles.rules = [
      "d ${zoneDir} 0755 knot knot -"
    ];

    systemd.services.knot = {
      after = [ "dome-dns-zone.service" ];
      requires = [ "dome-dns-zone.service" ];
    };

    systemd.services.dome-dns-zone = {
      description = "Render dome.ms zone from inventory and etcd";
      wantedBy = [ "multi-user.target" ];
      before = [ "knot.service" ];
      after = [
        "network-online.target"
        "etcd.service"
      ];
      wants = [ "network-online.target" ];
      path = with pkgs; [
        coreutils
        gawk
        gnused
        jq
        etcd
        systemd
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = renderZone;
      };
    };

    systemd.timers.dome-dns-zone = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15s";
        OnUnitActiveSec = "1min";
      };
    };
  };
}
