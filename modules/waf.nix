{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dome.waf;
  crs = pkgs.modsecurity-crs;
  rules = pkgs.writeText "modsecurity.conf" ''
    SecRuleEngine ${if cfg.blocking then "On" else "DetectionOnly"}

    SecRequestBodyAccess On
    SecRequestBodyLimit 13107200
    SecRequestBodyNoFilesLimit 131072
    SecRequestBodyLimitAction Reject
    SecRequestBodyJsonDepthLimit 512
    SecArgumentsLimit 1000
    SecResponseBodyAccess Off

    SecRule REQUEST_HEADERS:Content-Type "^(?:application(?:/soap\+|/)|text/)xml" \
      "id:200000,phase:1,t:none,t:lowercase,pass,nolog,ctl:requestBodyProcessor=XML"
    SecRule REQUEST_HEADERS:Content-Type "^application/json" \
      "id:200001,phase:1,t:none,t:lowercase,pass,nolog,ctl:requestBodyProcessor=JSON"
    SecRule &ARGS "@ge 1000" \
      "id:200007,phase:2,t:none,log,deny,status:400,msg:'Failed to fully parse request body due to large argument count',severity:2"
    SecRule REQBODY_ERROR "!@eq 0" \
      "id:200002,phase:2,t:none,log,deny,status:400,msg:'Failed to parse request body.',logdata:'%{reqbody_error_msg}',severity:2"

    SecTmpDir /tmp/
    SecDataDir /tmp/

    SecAuditEngine RelevantOnly
    SecAuditLogRelevantStatus "^(?:5|4(?!04))"
    SecAuditLogParts ABIJDEFHZ
    SecAuditLogType Serial
    SecAuditLog /var/log/nginx/modsec_audit.log

    SecArgumentSeparator &
    SecCookieFormat 0
    SecStatusEngine Off

    Include ${crs}/share/modsecurity-crs/crs-setup.conf.example
    Include ${crs}/rules/*.conf
  '';
in
{
  config = lib.mkIf (config.dome.enable && config.dome.apps.enable) {
    services.nginx = {
      additionalModules = [ pkgs.nginxModules.modsecurity ];
      appendHttpConfig = ''
        modsecurity ${if cfg.enable then "on" else "off"};
        ${lib.optionalString cfg.enable "modsecurity_rules_file ${rules};"}
      '';
    };
  };
}
