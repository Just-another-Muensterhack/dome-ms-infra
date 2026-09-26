{ lib, inputs }:
lib.pipe
  (with inputs; [
    adminKeys-felixevers
    adminKeys-schnitzel4
  ])
  [
    (lib.concatMap (file: lib.splitString "\n" (builtins.readFile file)))
    (map lib.trim)
    (lib.filter (key: key != ""))
    lib.unique
  ]
