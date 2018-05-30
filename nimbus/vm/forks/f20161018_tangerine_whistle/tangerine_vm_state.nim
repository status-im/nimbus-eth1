# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../../../logging, ../../../constants, ../../../errors, ../../../vm_state,
  ../../../utils/header, ../../../db/db_chain

type
  TangerineVMState* = ref object of BaseVMState
    # receipts*:
    # computationClass*: Any
    # accessLogs*: AccessLogs

proc newTangerineVMState*: TangerineVMState =
  new(result)
  result.prevHeaders = @[]
  result.name = "TangerineVM"
  result.accessLogs = newAccessLogs()
  # result.blockHeader = # TODO: ...
