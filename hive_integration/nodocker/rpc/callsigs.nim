# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[os, strutils],
  eth/[common],
  json_rpc/[rpcclient],
  ../../../nimbus/rpc/[hexstrings, rpc_types]

template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]
const sigPath = sourceDir / ".." / ".." / ".." / "tests" / "rpcclient" / "ethcallsigs.nim"
createRpcSigs(RpcClient, sigPath)
