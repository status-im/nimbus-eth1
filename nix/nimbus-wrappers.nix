{ stdenv, callPackage, fetchFromGitHub, clang, go, nim, sqlite, pcre, rocksdb }:

{ buildSamples ? true }:

let
  inherit (stdenv.lib) concatMapStringsSep makeLibraryPath optional optionalString;

  mkFilter = callPackage ./mkFilter.nix { inherit (stdenv) lib; };
  vendorDeps = [
    "nim-chronicles" "nim-faststreams" "nim-json-serialization" "nim-chronos" "nim-eth" "nim-json"
    "nim-metrics" "nim-secp256k1" "nim-serialization" "nim-stew" "nim-stint" "nimcrypto"
  ];

in

stdenv.mkDerivation rec {
  name = "nimbus-${version}";
  version = "0.0.1";

  src =
    let path = ./..; # Import the root /android and /mobile/js_files folders clean of any build artifacts
    in builtins.path { # We use builtins.path so that we can name the resulting derivation, otherwise the name would be taken from the checkout directory, which is outside of our control
      inherit path;
      name = "nimbus-sources";
      filter =
        # Keep this filter as restrictive as possible in order to avoid unnecessary rebuilds and limit closure size
        mkFilter {
          dirRootsToInclude = [
            "vendor" "wrappers"
          ];
          dirsToExclude = [ ".git" ".svn" "CVS" ".hg" "nimbus-build-system" "tests" ]
            ++ (builtins.map (dep: "vendor/${dep}") vendorDeps);
          filesToInclude = [ ];
          filesToExclude = [ "VERSION" "android/gradlew" ];
          root = path;
        };
    };
  nativeBuildInputs = optional buildSamples go;
  buildInputs = [ clang nim rocksdb pcre sqlite ];
  LD_LIBRARY_PATH = "${makeLibraryPath buildInputs}";

  buildPhase = ''
    mkdir -p $TMPDIR/.nimcache $TMPDIR/.nimcache_static ./build

    BUILD_MSG="\\e[92mBuilding:\\e[39m"
    export CC="${clang}/bin/clang"

    ln -s nimbus.nimble nimbus.nims

    vendorPathOpts="${concatMapStringsSep " " (dep: "--path:./vendor/${dep}") vendorDeps}"
    echo -e $BUILD_MSG "build/libnimbus.so" && \
      ${nim}/bin/nim c --app:lib --noMain --nimcache:$TMPDIR/.nimcache -d:release ''${vendorPathOpts} -o:./build/libnimbus.so wrappers/libnimbus.nim
    echo -e $BUILD_MSG "build/libnimbus.a" && \
      ${nim}/bin/nim c --app:staticlib --noMain --nimcache:$TMPDIR/.nimcache_static -d:release ''${vendorPathOpts} -o:build/libnimbus.a wrappers/libnimbus.nim && \
      [[ -e "libnimbus.a" ]] && mv "libnimbus.a" build/ # workaround for https://github.com/nim-lang/Nim/issues/12745

    rm -rf $TMPDIR/.nimcache $TMPDIR/.nimcache_static
  '' +
  optionalString buildSamples ''
    mkdir -p $TMPDIR/.home/.cache
    export HOME=$TMPDIR/.home

    echo -e $BUILD_MSG "build/C_wrapper_example" && \
      $CC wrappers/wrapper_example.c -Wl,-rpath,'$$ORIGIN' -Lbuild -lnimbus -lm -g -o build/C_wrapper_example
    echo -e $BUILD_MSG "build/go_wrapper_example" && \
      ${go}/bin/go build -o build/go_wrapper_example wrappers/wrapper_example.go wrappers/cfuncs.go
    echo -e $BUILD_MSG "build/go_wrapper_whisper_example" && \
      ${go}/bin/go build -o build/go_wrapper_whisper_example wrappers/wrapper_whisper_example.go wrappers/cfuncs.go

    rm -rf $TMPDIR/.home/.cache
  '';
  installPhase = ''
    mkdir -p $out/{include,lib}
    cp ./wrappers/libnimbus.h $out/include/
    cp ./build/libnimbus.{a,so} $out/lib/
  '' +
  optionalString buildSamples ''
    mkdir -p $out/samples
    cp ./build/{C_wrapper_example,go_wrapper_example,go_wrapper_whisper_example} $out/samples
  '';

  meta = with stdenv.lib; {
    description = "A C wrapper of the Nimbus Ethereum 2.0 Sharding Client for Resource-Restricted Devices";
    homepage = https://github.com/status-im/nimbus;
    license = with licenses; [ asl20 ];
    platforms = with platforms; unix ++ windows;
  };
}
