{ pkgs ? import <nixpkgs> { } }:

let
  tools = pkgs.callPackage ./tools.nix {};
  source = ../execution_chain/version.nim;

  major = tools.findKeyValue " +NimbusMajor\\* = ([0-9]+)$" source;
  minor = tools.findKeyValue " +NimbusMinor\\* = ([0-9]+)$" source;
  build = tools.findKeyValue " +NimbusPatch\\* = ([0-9]+)$" source;
in
  "${major}.${minor}.${build}"
