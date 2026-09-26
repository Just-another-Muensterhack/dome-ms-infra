{ pkgs, inputs }:
let
  public = "${inputs.backend}/web/public";
in
pkgs.runCommand "keycloak-theme-dome" { } ''
  cp -r ${./theme} $out
  chmod -R u+w $out
  res=$out/login/resources
  mkdir -p $res/fonts $res/img
  cp "${public}/fonts/Inter-VariableFont_opsz,wght.ttf" $res/fonts/Inter.ttf
  cp "${public}/fonts/SpaceGrotesk-VariableFont_wght.ttf" $res/fonts/SpaceGrotesk.ttf
  cp ${public}/logo-lightmode.svg ${public}/logo-darkmode.svg ${public}/favicon.ico $res/img/
''
