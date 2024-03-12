# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

##
## Snapshot Structure for Clique PoA Consensus Protocol
## ====================================================
##
## For details see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##

import
  std/tables,
  chronicles,
  eth/rlp,
  results,
  ../../../db/[core_db, storage_types],
  ../clique_cfg,
  ../clique_defs,
  ../clique_helpers,
  ./ballot

export tables

type
  SnapshotResult* = ##\
    ## Snapshot/error result type
    Result[Snapshot,CliqueError]

  AddressHistory* = Table[BlockNumber,EthAddress]

  SnapshotData* = object
    blockNumber: BlockNumber  ## block number where snapshot was created on
    blockHash: Hash256        ## block hash where snapshot was created on
    recents: AddressHistory   ## recent signers for spam protections

    # clique/snapshot.go(58): Recents map[uint64]common.Address [..]
    ballot: Ballot            ## Votes => authorised signers

  # clique/snapshot.go(50): type Snapshot struct [..]
  Snapshot* = ref object      ## Snapshot is the state of the authorization
                              ## voting at a given point in time.
    cfg: CliqueCfg            ## parameters to fine tune behavior
    data*: SnapshotData       ## real snapshot

{.push raises: [].}

logScope:
  topics = "clique PoA snapshot"

# ------------------------------------------------------------------------------
# Private functions needed to support RLP conversion
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Clique " & info

proc append[K,V](rw: var RlpWriter; tab: Table[K,V]) =
  rw.startList(tab.len)
  for key,value in tab.pairs:
    rw.append((key,value))

proc read[K,V](rlp: var Rlp;
        Q: type Table[K,V]): Q {.gcsafe, raises: [CatchableError].} =
  for w in rlp.items:
    let (key,value) = w.read((K,V))
    result[key] = value

# ------------------------------------------------------------------------------
# Private constructor helper
# ------------------------------------------------------------------------------

# clique/snapshot.go(72): func newSnapshot(config [..]
proc initSnapshot(s: Snapshot; cfg: CliqueCfg;
           number: BlockNumber; hash: Hash256; signers: openArray[EthAddress]) =
  ## Initalise a new snapshot.
  s.cfg = cfg
  s.data.blockNumber = number
  s.data.blockHash = hash
  s.data.recents = initTable[BlockNumber,EthAddress]()
  s.data.ballot.initBallot(signers)

# ------------------------------------------------------------------------------
# Public Constructor
# ------------------------------------------------------------------------------

proc newSnapshot*(cfg: CliqueCfg; header: BlockHeader): Snapshot =
  ## Create a new snapshot for the given header. The header need not be on the
  ## block chain, yet. The trusted signer list is derived from the
  ## `extra data` field of the header.
  new result
  let signers = header.extraData.extraDataAddresses
  result.initSnapshot(cfg, header.blockNumber, header.blockHash, signers)

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc cfg*(s: Snapshot): CliqueCfg =
  ## Getter
  s.cfg

proc blockNumber*(s: Snapshot): BlockNumber =
  ## Getter
  s.data.blockNumber

proc blockHash*(s: Snapshot): Hash256 =
  ## Getter
  s.data.blockHash

proc recents*(s: Snapshot): var AddressHistory =
  ## Retrieves the list of recently added addresses
  s.data.recents

proc ballot*(s: Snapshot): var Ballot =
  ## Retrieves the ballot box descriptor with the votes
  s.data.ballot

# ------------------------------------------------------------------------------
# Public setters
# ------------------------------------------------------------------------------

proc `blockNumber=`*(s: Snapshot; number: BlockNumber) =
  ## Getter
  s.data.blockNumber = number

proc `blockHash=`*(s: Snapshot; hash: Hash256) =
  ## Getter
  s.data.blockHash = hash

# ------------------------------------------------------------------------------
# Public load/store support
# ------------------------------------------------------------------------------

# clique/snapshot.go(88): func loadSnapshot(config [..]
proc loadSnapshot*(cfg: CliqueCfg; hash: Hash256):
                 Result[Snapshot,CliqueError] =
  ## Load an existing snapshot from the database.
  var s = Snapshot(cfg: cfg)
  try:
    let rc = s.cfg.db.newKvt(cliqueSnapshot, Shared).get(hash.data)
    if rc.isOk:
      s.data = rc.value.decode(SnapshotData)
    else:
      if rc.error.error != KvtNotFound:
        error logTxt "get() failed", error=($$rc.error)
      return err((errSnapshotLoad,""))
  except CatchableError as e:
    return err((errSnapshotLoad, $e.name & ": " & e.msg))
  ok(s)

# clique/snapshot.go(104): func (s *Snapshot) store(db [..]
proc storeSnapshot*(cfg: CliqueCfg; s: Snapshot): CliqueOkResult =
  ## Insert the snapshot into the database.
  try:
    let
      val = rlp.encode(s.data)
      kvt = s.cfg.db.newKvt(cliqueSnapshot, Companion)
    kvt.put(s.data.blockHash.data, val).isOkOr:
      error logTxt "put() failed", `error`=($$error)
    kvt.persistent()

    cfg.nSnaps.inc
    cfg.snapsData += val.len.uint
  except CatchableError as e:
    return err((errSnapshotStore, $e.name & ": " & e.msg))

  ok()

# ------------------------------------------------------------------------------
# Public deep copy
# ------------------------------------------------------------------------------

proc cloneSnapshot*(s: Snapshot): Snapshot =
  ## Clone the snapshot
  Snapshot(
    cfg: s.cfg,   # copy ref
    data: s.data) # copy data

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
