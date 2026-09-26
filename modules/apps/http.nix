{ config, lib }:
{
  tls = {
    forceSSL = true;
    useACMEHost = lib.mkIf config.dome.acme.enable "dome.ms";
    enableACME = false;
    sslCertificate = lib.mkIf (!config.dome.acme.enable) "${config.dome.pki.dir}/node.crt";
    sslCertificateKey = lib.mkIf (!config.dome.acme.enable) "${config.dome.pki.dir}/node.key";
  };

  proxy = port: {
    proxyPass = "http://127.0.0.1:${toString port}";
    proxyWebsockets = true;
    recommendedProxySettings = true;
  };
}
