{ stdenv, lib, makeWrapper, nodejs, openssl, pcre, readline, sqlite, nim }:

stdenv.mkDerivation rec {
  # This derivation may be a bit confusing at first, because it builds the Status'
  # Nimbus branch of Nim using the standard Nim compiler provided by Nix.
  #
  # It's mostly a copy of the original Nim recipe, but uses git to obtain the
  # sources and have a simplified `buildPhase`.
  #
  # For maintainance, you only need to bump the obtained git revision from time
  # to time.

  name = "status-nim";
  version = "0.18.1";

  src = fetchGit {
    url = "git://github.com/status-im/Nim";
    ref = "nimbus";

    # Set this to the hash of the head commit in the nimbus branch:
    rev = "d40fb5a6d3ed937d41fd0e72a27df8c397aae881";
  };

  doCheck = true;

  enableParallelBuilding = true;

  NIX_LDFLAGS = [
    "-lcrypto"
    "-lpcre"
    "-lreadline"
    "-lsqlite3"
  ];

  # 1. nodejs is only needed for tests
  # 2. we could create a separate derivation for the "written in c" version of nim
  #    used for bootstrapping, but koch insists on moving the nim compiler around
  #    as part of building it, so it cannot be read-only

  buildInputs  = [
    makeWrapper nodejs nim
    openssl pcre readline sqlite
  ];

  buildPhase   = ''
    nim c --lib:"./lib" -d:release koch.nim
    nim c --lib:"./lib" -d:release compiler/nim.nim && mv compiler/nim bin/
  '';

  installPhase = ''
    install -Dt $out/bin bin/* koch
    ./koch install $out
    mv $out/nim/bin/* $out/bin/ && rmdir $out/nim/bin
    mv $out/nim/*     $out/     && rmdir $out/nim
    wrapProgram $out/bin/nim \
      --suffix PATH : ${lib.makeBinPath [ stdenv.cc ]}
  '';

  meta = with stdenv.lib; {
    description = "Status's build of Nim";
    homepage = https://nim-lang.org/;
    license = licenses.mit;
    maintainers = with maintainers; [ ehmry peterhoeg ];
    platforms = with platforms; linux ++ darwin; # arbitrary
  };
}

