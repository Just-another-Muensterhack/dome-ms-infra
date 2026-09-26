{
  description = "dome.ms";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    backend = {
      url = "github:Just-another-Muensterhack/dome-ms-backend";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    adminKeys-felixevers = {
      url = "https://github.com/felixevers.keys";
      flake = false;
    };

    adminKeys-schnitzel4 = {
      url = "https://github.com/schnitzel4.keys";
      flake = false;
    };
  };

  outputs =
    {
      nixpkgs,
      backend,
      comin,
      sops-nix,
      disko,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;
      adminSshKeys = import ./admin-keys.nix { inherit lib inputs; };

      defaultSystems = [ "x86_64-linux" ];
      eachDefaultSystem = lib.genAttrs defaultSystems;

      # Recursively find all directories containing configuration.nix
      listHosts =
        dir:
        if builtins.pathExists (dir + "/configuration.nix") then
          [ dir ]
        else
          let
            subdirs = lib.filterAttrs (_: type: type == "directory") (builtins.readDir dir);
          in
          builtins.concatLists (map (name: listHosts (dir + "/${name}")) (builtins.attrNames subdirs));

      hosts = listHosts ./hosts;

      makeFqdn =
        path:
        lib.pipe path [
          (lib.path.removePrefix ./hosts)
          lib.path.subpath.components
          lib.reverseList
          (builtins.concatStringsSep ".")
        ];

      getSystem =
        hostPath:
        let
          sysFile = hostPath + "/system.txt";
        in
        if builtins.pathExists sysFile then
          lib.removeSuffix "\n" (builtins.readFile sysFile)
        else
          "x86_64-linux";

    in
    {
      nixosConfigurations = builtins.listToAttrs (
        map (
          hostPath:
          let
            fqdn = makeFqdn hostPath;
            system = getSystem hostPath;
          in
          {
            name = fqdn;
            value = lib.nixosSystem {
              inherit system;

              specialArgs = { inherit inputs fqdn hostPath; };
              modules = [
                comin.nixosModules.comin
                sops-nix.nixosModules.sops
                disko.nixosModules.disko

                (hostPath + "/configuration.nix")

                ./modules/base.nix

                {
                  dome = {
                    enable = true;
                    admin.sshKeys = adminSshKeys;
                    acme.production = true;
                  };
                  networking.hostName = builtins.head (lib.splitString "." fqdn);
                  networking.domain = builtins.concatStringsSep "." (builtins.tail (lib.splitString "." fqdn));
                }
              ];
            };
          }
        ) hosts
      );

      devShells = eachDefaultSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              sops
              ssh-to-age
              nixos-anywhere
              nixfmt
              deadnix
              gitleaks
              yq
              age
              fd
              openssl
              python3
            ];
          };
        }
      );

      checks = eachDefaultSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          cluster = import ./tests/cluster.nix {
            inherit pkgs inputs;
            seed =
              let
                fromEnv = builtins.getEnv "DOME_TEST_SEED";
              in
              if fromEnv == "" then "0" else fromEnv;
          };
        }
      );
    };
}
