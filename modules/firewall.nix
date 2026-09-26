{ config, lib, ... }:
let
  ports = config.dome.firewall.peerTCPPorts;
  portSet = lib.concatMapStringsSep ", " toString ports;
in
{
  config = lib.mkIf config.dome.enable {
    networking.firewall.allowedTCPPorts = [
      80
      443
    ]
    ++ ports;

    networking.nftables.tables.dome = {
      family = "inet";
      content = ''
        set peers4 {
          type ipv4_addr
        }

        set peers6 {
          type ipv6_addr
        }

        chain input {
          type filter hook input priority filter - 1; policy accept;
          ${lib.optionalString (ports != [ ]) ''
            iifname "lo" accept
            tcp dport { ${portSet} } ip saddr @peers4 accept
            tcp dport { ${portSet} } ip6 saddr @peers6 accept
            tcp dport { ${portSet} } drop
          ''}
        }
      '';
    };
  };
}
