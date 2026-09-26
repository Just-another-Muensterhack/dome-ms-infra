{
  config,
  lib,
  fqdn,
  ...
}:
let
  cfg = config.dome.repo;
in
{
  config = lib.mkIf config.dome.enable {
    sops.secrets = lib.mkIf cfg.private {
      "comin/access_token".sopsFile = config.dome.sops.clusterFile;
    };

    services.comin = {
      enable = true;
      hostname = fqdn;
      remotes = [
        (
          {
            name = "origin";
            url = cfg.url;
            branches.main.name = cfg.branch;
          }
          // lib.optionalAttrs cfg.private {
            auth.access_token_path = config.sops.secrets."comin/access_token".path;
          }
        )
      ];
    };
  };
}
