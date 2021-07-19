# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
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
  std/[algorithm, sequtils, strformat, strutils, tables],
  ../../../db/storage_types,
  ../../../utils,
  ../clique_cfg,
  ../clique_defs,
  ../clique_helpers,
  ./ballot,
  chronicles,
  eth/[common, rlp, trie/db],
  stew/results

type
  SnapshotResult* = ##\
    ## Snapshot/error result type
    Result[Snapshot,CliqueError]

  AddressHistory = Table[BlockNumber,EthAddress]

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

{.push raises: [Defect].}

logScope:
  topics = "clique PoA snapshot"

# ------------------------------------------------------------------------------
# Pretty printers for debugging
# ------------------------------------------------------------------------------

proc getPrettyPrinters*(s: Snapshot): var PrettyPrinters {.gcsafe.}
proc pp*(s: Snapshot; v: Vote): string {.gcsafe.}

proc votesList(s: Snapshot; sep: string): string =
  proc s3Cmp(a, b: (string,string,Vote)): int =
    result = cmp(a[0], b[0])
    if result == 0:
      result = cmp(a[1], b[1])
  s.data.ballot.votesInternal
    .mapIt((s.pp(it[0]),s.pp(it[1]),it[2]))
    .sorted(cmp = s3cmp)
    .mapIt(s.pp(it[2]))
    .join(sep)

proc signersList(s: Snapshot): string =
  s.pp(s.data.ballot.authSigners).sorted.join(",")

# ------------------------------------------------------------------------------
# Private functions needed to support RLP conversion
# ------------------------------------------------------------------------------

proc append[K,V](rw: var RlpWriter; tab: Table[K,V]) {.inline.} =
  rw.startList(tab.len)
  for key,value in tab.pairs:
    rw.append((key,value))

proc read[K,V](rlp: var Rlp;
        Q: type Table[K,V]): Q {.inline, raises: [Defect,CatchableError].} =
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
  s.data.ballot.debug = s.cfg.debug

# ------------------------------------------------------------------------------
# Public pretty printers
# ------------------------------------------------------------------------------

proc getPrettyPrinters*(s: Snapshot): var PrettyPrinters =
  ## Mixin for pretty printers
  s.cfg.prettyPrint

proc pp*(s: Snapshot; h: var AddressHistory): string {.gcsafe.} =
  ppExceptionWrap:
    toSeq(h.keys)
      .sorted
      .mapIt("#" & $it & ":" & s.pp(h[it.u256]))
      .join(",")

proc pp*(s: Snapshot; v: Vote): string =
  proc authorized(b: bool): string =
    if b: "authorise" else: "de-authorise"
  ppExceptionWrap:
    "(" & &"address={s.pp(v.address)}" &
          &",signer={s.pp(v.signer)}" &
          &",blockNumber={v.blockNumber}" &
          &",{authorized(v.authorize)}" & ")"

proc pp*(s: Snapshot; delim: string): string {.gcsafe.} =
  ## Pretty print descriptor
  let
    sep1 = if 0 < delim.len: delim
           else: ";"
    sep2 = if 0 < delim.len and delim[0] == '\n': delim & ' '.repeat(7)
           else: ";"
  ppExceptionWrap:
    &"(blockNumber=#{s.data.blockNumber}" &
      &"{sep1}recents=" & "{" & s.pp(s.data.recents) & "}" &
      &"{sep1}signers=" & "{" & s.signersList & "}" &
      &"{sep1}votes=[" & s.votesList(sep2) & "])"

proc pp*(s: Snapshot; indent = 0): string {.gcsafe.} =
  ## Pretty print descriptor
  let delim = if 0 < indent: "\n" & ' '.repeat(indent) else: " "
  s.pp(delim)

# ------------------------------------------------------------------------------
# Public Constructor
# ------------------------------------------------------------------------------

proc newSnapshot*(cfg: CliqueCfg; header: BlockHeader): Snapshot =
  ## Create a new snapshot for the given header. The header need not be on the
  ## block chain, yet. The trusted signer list is derived from the
  ## `extra data` field of the header.
  new result
  let signers = header.extraData.extraDataAddresses
  result.initSnapshot(cfg, header.blockNumber, header.hash, signers)

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc cfg*(s: Snapshot): CliqueCfg {.inline.} =
  ## Getter
  s.cfg

proc blockNumber*(s: Snapshot): BlockNumber {.inline.} =
  ## Getter
  s.data.blockNumber

proc blockHash*(s: Snapshot): Hash256 {.inline.} =
  ## Getter
  s.data.blockHash

proc recents*(s: Snapshot): var AddressHistory {.inline.} =
  ## Retrieves the list of recently added addresses
  s.data.recents

proc ballot*(s: Snapshot): var Ballot {.inline.} =
  ## Retrieves the ballot box descriptor with the votes
  s.data.ballot

# ------------------------------------------------------------------------------
# Public setters
# ------------------------------------------------------------------------------

proc `blockNumber=`*(s: Snapshot; number: BlockNumber) {.inline.} =
  ## Getter
  s.data.blockNumber = number

proc `blockHash=`*(s: Snapshot; hash: Hash256) {.inline.} =
  ## Getter
  s.data.blockHash = hash

# ------------------------------------------------------------------------------
# Public load/store support
# ------------------------------------------------------------------------------

# clique/snapshot.go(88): func loadSnapshot(config [..]
proc loadSnapshot*(cfg: CliqueCfg; hash: Hash256):
                   Result[Snapshot,CLiqueError] {.gcsafe, raises: [Defect].} =
  ## Load an existing snapshot from the database.
  var s = Snapshot(cfg: cfg)
  try:
    s.data = s.cfg.db.db
       .get(hash.cliqueSnapshotKey.toOpenArray)
       .decode(SnapshotData)
    s.data.ballot.debug = s.cfg.debug
  except CatchableError as e:
    return err((errSnapshotLoad,e.msg))
  result = ok(s)

# clique/snapshot.go(104): func (s *Snapshot) store(db [..]
proc storeSnapshot*(s: Snapshot): CliqueOkResult {.gcsafe,raises: [Defect].} =
  ## Insert the snapshot into the database.
  try:
    s.cfg.db.db
       .put(s.data.blockHash.cliqueSnapshotKey.toOpenArray, rlp.encode(s.data))
  except CatchableError as e:
    return err((errSnapshotStore,e.msg))
  result = ok()

# ------------------------------------------------------------------------------
# Public deep copy
# ------------------------------------------------------------------------------

proc cloneSnapshot*(s: Snapshot): Snapshot {.inline.} =
  ## Clone the snapshot
  Snapshot(
    cfg: s.cfg,   # copy ref
    data: s.data) # copy data

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
