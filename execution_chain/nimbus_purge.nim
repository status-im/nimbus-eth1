# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  chronicles,
  # metrics,
  # chronos/timer,
  # std/[strformat, strutils],
  # stew/io2,
  ./conf,
  ./common/common,
  ./core/chain

proc purge*(config: ExecutionClientConf, com: CommonRef) =
  let
    start = com.db.baseTxFrame().getSavedStateBlockNumber()
  notice "Current database at", blockNumber = start