# nimbus-eth1
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  chronicles,
  eth/[common, p2p],
  ../../range_desc,
  "."/[hexary_desc, hexary_error, snapdb_desc, snapdb_persistent]

logScope:
  topics = "snap-db"

type
  SnapDbContractsRef* = ref object of SnapDbBaseRef
    peer: Peer               ## For log messages

when false:
  const
    extraTraceMessages = false or true

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

when false:
  template noExceptionOops(info: static[string]; code: untyped) =
    try:
      code
    except CatchableError as e:
      raiseAssert "Not possible -- " & info & ": " & e.msg

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc persistentContracts(
    ps: SnapDbContractsRef;    ## Base descriptor on `CoreDbRef`
    data: seq[(NodeKey,Blob)]; ## Contract code items
      ): Result[void,HexaryError]
      {.gcsafe, raises: [OSError,IOError,KeyError].} =
  ## Store contract codes onto permanent database
  if ps.rockDb.isNil:
    let rc = data.persistentContractPut ps.kvDb
    if rc.isErr:
      return rc
  else:
    let rc = data.persistentContractPut ps.rockDb
    if rc.isErr:
      return rc
  ok()

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    T: type SnapDbContractsRef;
    pv: SnapDbRef;
    peer: Peer = nil
      ): T =
  ## Constructor, starts a new accounts session.
  new result
  result.init(pv, NodeKey.default)
  result.peer = peer

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getContractsFn*(desc: SnapDbBaseRef|SnapDbRef): HexaryGetFn =
  ## Return `HexaryGetFn` closure.
  let getFn = desc.kvDb.persistentContractsGetFn()
  return proc(key: openArray[byte]): Blob = getFn(key)


proc importContracts*(
    ps: SnapDbContractsRef;    ## Re-usable session descriptor
    data: seq[(NodeKey,Blob)]; ## Contract code items
      ): Result[void,HexaryError] =
  ## Store contract codes onto permanent database
  try:
    result = ps.persistentContracts data
  except RlpError:
    return err(RlpEncoding)
  except KeyError as e:
    raiseAssert "Not possible @ importAccounts(KeyError): " & e.msg
  except OSError as e:
    error "Import Accounts exception", peer=ps.peer, name=($e.name), msg=e.msg
    return err(OSErrorException)
  except CatchableError as e:
    raiseAssert "Not possible @ importAccounts(" & $e.name & "):" & e.msg

proc importContracts*(
    pv: SnapDbRef;            ## Base descriptor on `CoreDbRef`
    peer: Peer;               ## For log messages
    data: seq[(NodeKey,Blob)]; ## Contract code items
      ): Result[void,HexaryError] =
  ## Variant of `importAccounts()` for presistent storage, only.
  SnapDbContractsRef.init(pv, peer).importContracts(data)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
