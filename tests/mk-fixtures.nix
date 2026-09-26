{
  pkgs,
  seed ? "0",
}:
pkgs.runCommand "dome-test-fixtures-${seed}"
  {
    inherit seed;
    nativeBuildInputs = with pkgs; [
      age
      sops
      openssl
      python3
    ];
  }
  ''
    export HOME="$TMPDIR"
    bash ${./gen-fixtures.sh} "$out"
  ''
