{ pkgs ? import <nixpkgs> {} }:

let
  stdenv = pkgs.stdenv;

in

stdenv.mkDerivation rec {
  name = "nimbus-${version}";
  version = "0.0.1";

  meta = with stdenv.lib; {
    description = "An Ethereum 2.0 Sharding Client for Resource-Restricted Devices";
    homepage = https://github.com/status-im/nimbus;
    license = [licenses.asl20];
    platforms = platforms.unix;
  };

  src = ./.;
  buildInputs = [pkgs.clang pkgs.nim pkgs.rocksdb pkgs.secp256k1 pkgs.cryptopp];
}

