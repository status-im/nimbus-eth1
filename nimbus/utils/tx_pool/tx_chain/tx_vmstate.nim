# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Block Chain Helper: vmState Transaction Framework
## =================================================
##

import
  ../../../db/[db_chain, accounts_cache],
  ../../../vm_state,
  ../../../vm_types,
  eth/[common]

{.push raises: [Defect].}

type
  TxVmStateError* = object of CatchableError
    ## Catch and relay exception error

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template safeExecutor(info: string; code: untyped) =
  try:
    code
  except CatchableError as e:
    raise (ref CatchableError)(msg: e.msg)
  except Defect as e:
    raise (ref Defect)(msg: e.msg)
  except:
    let e = getCurrentException()
    raise newException(
      TxVmStateError, info & "(): " & $e.name & " -- " & e.msg)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc vmStateGet*(db: BaseChainDB; newHead: BlockHeader): BaseVMState
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Set up accounting state descriptor
  safeExecutor "tx_vmstate.vmStateGet()":
    let stateRoot = AccountsCache.init(
      db.db, newHead.stateRoot, db.pruneTrie)
    result = newBaseVMState(stateRoot, newHead, db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
