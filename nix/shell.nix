{ pkgs ? import <nixpkgs> {}, nim }:

let
  package = pkgs.callPackage ./default.nix { inherit nim; };
in pkgs.mkShell {
  inputsFrom = [ package ];

  buildInputs = with pkgs; [
    git
    git-lfs
    getopt

    # For the local simulation
    openssl # for generating the JWT file
    lsof    # for killing processes by port
    killall # for killing processes manually
    procps  # for killing processes with pkill
    curl    # for working with the node APIs
    jq      # for parsing beacon API for LC start
  ];

  shellHook = ''
    # By default, the Nix wrapper scripts for executing the system compilers
    # will erase `-march=native` because this introduces impurity in the build.
    # For the purposes of compiling Nimbus, this behavior is not desired:
    export NIX_ENFORCE_NO_NATIVE=0
    export USE_SYSTEM_GETOPT=1
    export MAKEFLAGS="-j$NIX_BUILD_CORES"
  '';
}
