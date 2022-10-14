# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[tables],
  chronicles,
  eth/[common/eth_types, p2p],
  ../../../protocol,
  ../../range_desc,
  "."/[bulk_storage, hexary_desc, hexary_error, hexary_interpolate, snapdb_desc]

{.push raises: [Defect].}

logScope:
  topics = "snap-db"

const
  extraTraceMessages = false or true

type
  SnapDbStorageSlotsRef* = ref object of SnapDbBaseRef
    accHash*: Hash256                ## Accounts address hash (curr.unused)

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc to(h: Hash256; T: type NodeKey): T =
  h.data.T

proc convertTo(data: openArray[byte]; T: type Hash256): T =
  discard result.data.NodeKey.init(data) # size error => zero

template noKeyError(info: static[string]; code: untyped) =
  try:
    code
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg

template noRlpExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except RlpError:
    return err(RlpEncoding)
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg
  except Defect as e:
    raise e
  except Exception as e:
    raiseAssert "Ooops " & info & ": name=" & $e.name & " msg=" & e.msg

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc persistentStorages(
    db: HexaryTreeDbRef;       ## Current table
    ps: SnapDbStorageSlotsRef; ## For persistent database
      ): Result[void,HexaryDbError]
      {.gcsafe, raises: [Defect,OSError,KeyError].} =
  ## Store accounts trie table on databse
  if ps.rockDb.isNil:
    let rc = db.bulkStorageStorages(ps.kvDb)
    if rc.isErr: return rc
  else:
    let rc = db.bulkStorageStoragesRocky(ps.rockDb)
    if rc.isErr: return rc
  ok()


proc collectStorageSlots(
    peer: Peer;
    slots: seq[SnapStorage];
      ): Result[seq[RLeafSpecs],HexaryDbError]
      {.gcsafe, raises: [Defect, RlpError].} =
  ## Similar to `collectAccounts()`
  var rcSlots: seq[RLeafSpecs]

  if slots.len != 0:
    # Add initial account
    rcSlots.add RLeafSpecs(
      pathTag: slots[0].slotHash.to(NodeTag),
      payload: slots[0].slotData)

    # Veify & add other accounts
    for n in 1 ..< slots.len:
      let nodeTag = slots[n].slotHash.to(NodeTag)

      if nodeTag <= rcSlots[^1].pathTag:
        let error = SlotsNotSrictlyIncreasing
        trace "collectStorageSlots()", peer, item=n, slots=slots.len, error
        return err(error)

      rcSlots.add RLeafSpecs(pathTag: nodeTag, payload: slots[n].slotData)

  ok(rcSlots)


proc importStorageSlots(
    ps: SnapDbStorageSlotsRef; ## Re-usable session descriptor
    data: AccountSlots;        ## Account storage descriptor
    proof: SnapStorageProof;   ## Account storage proof
      ): Result[void,HexaryDbError]
      {.gcsafe, raises: [Defect,RlpError,KeyError].} =
  ## Preocess storage slots for a particular storage root
  let
    root = data.account.storageRoot.to(NodeKey)
    tmpDb = SnapDbBaseRef.init(ps, ps.root, ps.peer)
  var
    slots: seq[RLeafSpecs]
  if 0 < proof.len:
    let rc = tmpDb.mergeProofs(root, proof)
    if rc.isErr:
      return err(rc.error)
  block:
    let rc = ps.peer.collectStorageSlots(data.data)
    if rc.isErr:
      return err(rc.error)
    slots = rc.value
  block:
    let rc = tmpDb.hexaDb.hexaryInterpolate(
      root, slots, bootstrap = (proof.len == 0))
    if rc.isErr:
      return err(rc.error)

  # Commit to main descriptor
  for k,v in tmpDb.hexaDb.tab.pairs:
    if not k.isNodeKey:
      return err(UnresolvedRepairNode)
    ps.hexaDb.tab[k] = v

  ok()

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    T: type SnapDbStorageSlotsRef;
    pv: SnapDbRef;
    account = Hash256();
    root = Hash256();
    peer: Peer = nil
      ): T =
  ## Constructor, starts a new accounts session.
  new result
  result.init(pv, root.to(NodeKey), peer)
  result.accHash = account

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc importStorages*(
    ps: SnapDbStorageSlotsRef; ## Re-usable session descriptor
    data: AccountStorageRange; ## Account storage reply from `snap/1` protocol
    persistent = false;        ## store data on disk
      ): seq[HexaryNodeReport] =
  ## Validate and import storage slots (using proofs as received with the snap
  ## message `StorageRanges`). This function accumulates data in a memory table
  ## which can be written to disk with the argument `persistent` set `true`. The
  ## memory table is held in the descriptor argument`ps`.
  ##
  ## If there were an error when processing a particular argument `data` item,
  ## it will be reported with the return value providing argument slot/index
  ## end error code.
  ##
  ## If there was an error soring persistent data, the last report item will
  ## have an error code, only.
  ##
  ## TODO:
  ##   Reconsider how to handle the persistant storage trie, see
  ##   github.com/status-im/nim-eth/issues/9#issuecomment-814573755
  ##
  let
    peer = ps.peer
    nItems = data.storages.len
    sTop = nItems - 1
  var
    slot: Option[int]
  if 0 <= sTop:
    try:
      for n in 0 ..< sTop:
        # These ones never come with proof data
        slot = some(n)
        let rc = ps.importStorageSlots(data.storages[n], @[])
        if rc.isErr:
          result.add HexaryNodeReport(slot: slot, error: rc.error)
          trace "Storage slots item fails", peer, inx=n, nItems,
            slots=data.storages[n].data.len, proofs=0,
            error=rc.error, nErrors=result.len

      # Final one might come with proof data
      block:
        slot = some(sTop)
        let rc = ps.importStorageSlots(data.storages[sTop], data.proof)
        if rc.isErr:
          result.add HexaryNodeReport(slot: slot, error: rc.error)
          trace "Storage slots last item fails", peer, inx=sTop, nItems,
            slots=data.storages[sTop].data.len, proofs=data.proof.len,
            error=rc.error, nErrors=result.len

      # Store to disk
      if persistent and 0 < ps.hexaDb.tab.len:
        slot = none(int)
        let rc = ps.hexaDb.persistentStorages(ps)
        if rc.isErr:
          result.add HexaryNodeReport(slot: slot, error: rc.error)

    except RlpError:
      result.add HexaryNodeReport(slot: slot, error: RlpEncoding)
      trace "Storage slot node error", peer, slot, nItems,
        slots=data.storages[sTop].data.len, proofs=data.proof.len,
        error=RlpEncoding, nErrors=result.len
    except KeyError as e:
      raiseAssert "Not possible @ importStorages: " & e.msg
    except OSError as e:
      result.add HexaryNodeReport(slot: slot, error: OSErrorException)
      trace "Import storage slots exception", peer, slot, nItems,
        name=($e.name), msg=e.msg, nErrors=result.len

  when extraTraceMessages:
    if result.len == 0:
      trace "Storage slots imported", peer, nItems,
        slots=data.storages.len, proofs=data.proof.len

proc importStorages*(
    pv: SnapDbRef;             ## Base descriptor on `BaseChainDB`
    peer: Peer,                ## For log messages, only
    data: AccountStorageRange; ## Account storage reply from `snap/1` protocol
      ): seq[HexaryNodeReport] =
  ## Variant of `importStorages()`
  SnapDbStorageSlotsRef.init(
    pv, peer=peer).importStorages(data, persistent=true)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
