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
      ): (int,seq[HexaryNodeReport]) =
  ## Validate and import storage slots (using proofs as received with the snap
  ## message `StorageRanges`). This function accumulates data in a memory table
  ## which can be written to disk with the argument `persistent` set `true`. The
  ## memory table is held in the descriptor argument`ps`.
  ##
  ## Note that the `peer` argument is for log messages, only.
  ##
  ## If there was no serious error, the right entry of the return code tuple
  ## contains a list of reports that correspond to the respective position on
  ## the `data.storages` argument list.
  ##
  ## Errors are summed up at the left entry of the return code tuple. If the
  ## data could not be stored to disk, an additional entry is appended to the
  ## right entry reports list of the return code tuple indication why this
  ## happened.
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
    inx: int
    errors = 0
    report = newSeq[HexaryNodeReport](nItems + 1)
  if 0 <= sTop:
    try:
      for n in 0 ..< sTop:
        # These ones never come with proof data
        inx = n
        let rc = ps.importStorageSlots(data.storages[inx], @[])
        if rc.isErr:
          report[inx].error = rc.error
          errors.inc
          trace "Storage slots item fails", peer, inx, nItems,
            slots=data.storages[inx].data.len, proofs=0,
            error=report[inx].error, errors

      # Final one might come with proof data
      block:
        inx = sTop
        let rc = ps.importStorageSlots(data.storages[inx], data.proof)
        if rc.isErr:
          report[inx].error = rc.error
          errors.inc
          trace "Storage slots last item fails", peer, nItems,
            slots=data.storages[inx].data.len, proofs=data.proof.len,
            error=report[inx].error, errors

      # Store to disk
      block storePersistent:
        if persistent and 0 < ps.hexaDb.tab.len:
          inx = nItems
          let rc = ps.hexaDb.persistentStorages(ps)
          if rc.isErr:
            errors.inc
            report[inx].error = rc.error
            break storePersistent
        # Chop off last return list entry if everything is OK
        report.setLen(nItems)

    except RlpError:
      report[inx].error = RlpEncoding
      errors.inc
    except KeyError as e:
      raiseAssert "Not possible @ importAccounts: " & e.msg
    except OSError as e:
      trace "Import Accounts exception", peer=ps.peer, name=($e.name),
        msg=e.msg, errors
      report[inx].error = OSErrorException
      errors.inc

  when extraTraceMessages:
    if errors == 0:
      trace "Storage slots imported", peer=ps.peer,
        slots=data.storages.len, proofs=data.proof.len

  (errors, report)

proc importStorages*(
    pv: SnapDbRef;             ## Base descriptor on `BaseChainDB`
    peer: Peer,                ## For log messages, only
    data: AccountStorageRange; ## Account storage reply from `snap/1` protocol
      ): (int,seq[HexaryNodeReport]) =
  ## Variant of `importStorages()`
  SnapDbStorageSlotsRef.init(
    pv, peer=peer).importStorages(data, persistent=true)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
