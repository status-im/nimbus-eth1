# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, strutils, sequtils, macros,
  constants, logging, errors, opcode_values, computation, vm/stack, stint,
  ./vm_types


# Super dirty fix for https://github.com/status-im/nimbus/issues/46
# Pending https://github.com/status-im/nimbus/issues/36
# Disentangle opcode logic
from logic.call import runLogic, BaseCall


template run*(opcode: Opcode, computation: var BaseComputation) =
  # Hook for performing the actual VM execution
  # opcode.consumeGas(computation)

  if opcode.kind == Op.Call: # Super dirty fix for https://github.com/status-im/nimbus/issues/46
    # TODO remove this branch
    runLogic(BaseCall(opcode), computation)
  elif computation.gasCosts[opcode.kind].kind in {GckDynamic, GckComplex}:
    opcode.runLogic(computation)
  else:
    computation.gasMeter.consumeGas(computation.gasCosts[opcode], reason = $opcode.kind)
    opcode.runLogic(computation)

method logger*(opcode: Opcode): Logger =
  logging.getLogger(&"vm.opcode.{opcode.kind}")
