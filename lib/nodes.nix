{ lib }:
let
  inherit (lib)
    filterAttrs
    hasSuffix
    mapAttrs'
    nameValuePair
    removeSuffix
    ;

  hexDigit = {
    "0" = 0;
    "1" = 1;
    "2" = 2;
    "3" = 3;
    "4" = 4;
    "5" = 5;
    "6" = 6;
    "7" = 7;
    "8" = 8;
    "9" = 9;
    "a" = 10;
    "b" = 11;
    "c" = 12;
    "d" = 13;
    "e" = 14;
    "f" = 15;
  };

  hashFqdn =
    fqdn:
    let
      hex = builtins.substring 0 6 (builtins.hashString "sha256" fqdn);
      value = lib.foldl' (acc: c: acc * 16 + hexDigit.${c}) 0 (lib.stringToCharacters hex);
    in
    (lib.mod value 1000) + 1;

  enrich =
    fqdn: value:
    value
    // {
      inherit fqdn;
      sequenceOffset = value.sequenceOffset or (hashFqdn fqdn);
    };

  loadDir =
    dir:
    let
      entries =
        if builtins.pathExists dir then
          filterAttrs (name: type: type == "regular" && hasSuffix ".nix" name) (builtins.readDir dir)
        else
          { };
    in
    mapAttrs' (
      name: _:
      let
        fqdn = removeSuffix ".nix" name;
      in
      nameValuePair fqdn (enrich fqdn (import (dir + "/${name}")))
    ) entries;

  sharedNames = [
    "nodes.dome.ms"
    "ns.dome.ms"
    "dns.dome.ms"
    "acme.dome.ms"
    "status.dome.ms"
  ];

  hostsFile =
    nodes: platformHosts:
    let
      nodeLines = lib.concatLists (
        map (
          node:
          [
            "${node.ipv4} ${node.fqdn}"
            "${node.ipv6} ${node.fqdn}"
          ]
          ++ map (name: "${node.ipv4} ${name}") (sharedNames ++ platformHosts)
          ++ map (name: "${node.ipv6} ${name}") (sharedNames ++ platformHosts)
        ) (lib.attrValues nodes)
      );
    in
    lib.concatStringsSep "\n" nodeLines + "\n";

  nodesFile =
    nodes:
    lib.concatStringsSep "\n" (
      map (node: "${node.fqdn} ${node.ipv4} ${node.ipv6}") (lib.attrValues nodes)
    )
    + "\n";

  assertUniqueOffsets =
    nodes:
    let
      offsets = map (n: n.sequenceOffset) (lib.attrValues nodes);
      dupes = lib.filter (o: lib.count (x: x == o) offsets > 1) offsets;
    in
    {
      assertion = dupes == [ ];
      message = "duplicate sequence offsets among nodes: ${lib.concatStringsSep ", " (map toString (lib.unique dupes))}";
    };
in
{
  inherit
    hashFqdn
    enrich
    loadDir
    hostsFile
    nodesFile
    assertUniqueOffsets
    sharedNames
    ;
}
