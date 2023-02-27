# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  ../nimbus/vm_compile_info

import
  std/os,
  ./common,
  ./db/select_backend,
  ./core/chain

type
  NimbusNode = ref object
    dbBackend: ChainDB

let
  CONFIG_DATA_DIR = getHomeDir() / ".cache" / "nimbus"

proc start(nimbus: NimbusNode) =
  createDir(CONFIG_DATA_DIR)
  nimbus.dbBackend = newChainDB(CONFIG_DATA_DIR)
  let trieDB = trieDB nimbus.dbBackend
  let com = CommonRef.new(trieDB,
    true,
    MainNet,
    MainNet.networkParams
    )


when isMainModule:
  var nimbus = NimbusNode()

  # Print some information about the test
  var info = ""
  when defined(boehm_enabled):
    info = "Boehm gc debugging"
  else:
    when defined(default_enabled):
      info = "Gc debugging"
    else:
      info = "Release mode"
  echo "*** gabbleblotchit: ", info

  nimbus.start()
