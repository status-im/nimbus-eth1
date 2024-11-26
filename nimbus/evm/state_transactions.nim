# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ../constants,
  ./computation,
  ./interpreter_dispatch,
  ./state,
  ./types

{.push raises: [].}

proc postExecComputation(c: Computation) =
  if c.isSuccess:
    if c.fork < FkLondon:
      # EIP-3529: Reduction in refunds
      c.refundSelfDestruct()
  c.vmState.status = c.isSuccess

proc execComputation*(c: Computation) =
  c.execCallOrCreate()
  c.postExecComputation()

template execSysCall*(c: Computation) =
  # A syscall to EVM doesn't require
  # a pre or post ceremony
  c.execCallOrCreate()
