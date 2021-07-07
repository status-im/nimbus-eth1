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
  ../clique_cfg,
  ../clique_defs,
  ./ballot,
  chronicles,
  eth/[common, rlp, trie/db],
  stew/results

type
  AddressHistory = Table[BlockNumber,EthAddress]

  SnapshotData* = object
    blockNumber: BlockNumber  ## block number where snapshot was created on
    blockHash: Hash256        ## block hash where snapshot was created on
    recents: AddressHistory   ## recent signers for spam protections

    # clique/snapshot.go(58): Recents map[uint64]common.Address [..]
    ballot: Ballot            ## Votes => authorised signers
    debug: bool               ## debug mode

  # clique/snapshot.go(50): type Snapshot struct [..]
  Snapshot* = object ## Snapshot is the state of the authorization voting at
                     ## a given point in time.
    cfg: CliqueCfg           ## parameters to fine tune behavior
    data*: SnapshotData      ## real snapshot

{.push raises: [Defect].}

logScope:
  topics = "clique PoA snapshot"

# ------------------------------------------------------------------------------
# Pretty printers for debugging
# ------------------------------------------------------------------------------

proc getPrettyPrinters*(s: var Snapshot): var PrettyPrinters {.gcsafe.}
proc pp*(s: var Snapshot; v: Vote): string {.gcsafe.}

proc votesList(s: var Snapshot; sep: string): string =
  proc s3Cmp(a, b: (string,string,Vote)): int =
    result = cmp(a[0], b[0])
    if result == 0:
      result = cmp(a[1], b[1])
  s.data.ballot.votesInternal
    .mapIt((s.pp(it[0]),s.pp(it[1]),it[2]))
    .sorted(cmp = s3cmp)
    .mapIt(s.pp(it[2]))
    .join(sep)

proc signersList(s: var Snapshot): string =
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
# Public pretty printers
# ------------------------------------------------------------------------------

proc say*(s: var Snapshot; v: varargs[string,`$`]) {.gcsafe.} =
  ## Debugging output
  ppExceptionWrap:
    if s.data.debug:
      stderr.write "*** " & v.join & "\n"

proc getPrettyPrinters*(s: var Snapshot): var PrettyPrinters =
  ## Mixin for pretty printers
  s.cfg.prettyPrint

proc pp*(s: var Snapshot; h: var AddressHistory): string {.gcsafe.} =
  ppExceptionWrap:
    toSeq(h.keys)
      .sorted
      .mapIt("#" & $it & ":" & s.pp(h[it.u256]))
      .join(",")

proc pp*(s: var Snapshot; v: Vote): string =
  proc authorized(b: bool): string =
    if b: "authorise" else: "de-authorise"
  ppExceptionWrap:
    "(" & &"address={s.pp(v.address)}" &
          &",signer={s.pp(v.signer)}" &
          &",blockNumber={v.blockNumber}" &
          &",{authorized(v.authorize)}" & ")"

proc pp*(s: var Snapshot; delim: string): string {.gcsafe.} =
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

proc pp*(s: var Snapshot; indent = 0): string {.gcsafe.} =
  ## Pretty print descriptor
  let delim = if 0 < indent: "\n" & ' '.repeat(indent) else: " "
  s.pp(delim)

# ------------------------------------------------------------------------------
# Public Constructor
# ------------------------------------------------------------------------------

# clique/snapshot.go(72): func newSnapshot(config [..]
proc initSnapshot*(s: var Snapshot; cfg: CliqueCfg;
           number: BlockNumber; hash: Hash256; signers: openArray[EthAddress]) =
  ## This creates a new snapshot with the specified startup parameters. The
  ## method does not initialize the set of recent signers, so only ever use
  ## if for the genesis block.
  s.cfg = cfg
  s.data.blockNumber = number
  s.data.blockHash = hash
  s.data.recents = initTable[BlockNumber,EthAddress]()
  s.data.ballot.initBallot(signers)

proc initSnapshot*(cfg: CliqueCfg; number: BlockNumber; hash: Hash256;
                   signers: openArray[EthAddress]; debug = true): Snapshot =
  result.initSnapshot(cfg, number, hash, signers)

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc cfg*(s: var Snapshot): CliqueCfg {.inline.} =
  ## Getter
  s.cfg

proc blockNumber*(s: var Snapshot): BlockNumber {.inline.} =
  ## Getter
  s.data.blockNumber

proc blockHash*(s: var Snapshot): Hash256 {.inline.} =
  ## Getter
  s.data.blockHash

proc recents*(s: var Snapshot): var AddressHistory {.inline.} =
  ## Retrieves the list of recently added addresses
  s.data.recents

proc ballot*(s: var Snapshot): var Ballot {.inline.} =
  ## Retrieves the ballot box descriptor with the votes
  s.data.ballot

# ------------------------------------------------------------------------------
# Public setters
# ------------------------------------------------------------------------------

proc `blockNumber=`*(s: var Snapshot; number: BlockNumber) {.inline.} =
  ## Getter
  s.data.blockNumber = number

proc `blockHash=`*(s: var Snapshot; hash: Hash256) {.inline.} =
  ## Getter
  s.data.blockHash = hash

proc `debug=`*(s: var Snapshot; debug: bool) =
  ## Set debugging mode on/off
  s.data.debug = debug
  s.data.ballot.debug = debug

# ------------------------------------------------------------------------------
# Public load/store support
# ------------------------------------------------------------------------------

# clique/snapshot.go(88): func loadSnapshot(config [..]
proc loadSnapshot*(s: var Snapshot; cfg: CliqueCfg;
           hash: Hash256): CliqueResult {.gcsafe, raises: [Defect].} =
  ## Load an existing snapshot from the database.
  try:
    s.cfg = cfg
    s.data = s.cfg.db.db
       .get(hash.cliqueSnapshotKey.toOpenArray)
       .decode(SnapshotData)
  except CatchableError as e:
    return err((errSnapshotLoad,e.msg))
  result = ok()

# clique/snapshot.go(104): func (s *Snapshot) store(db [..]
proc storeSnapshot*(s: var Snapshot): CliqueResult {.gcsafe,raises: [Defect].} =
  ## Insert the snapshot into the database.
  try:
    s.cfg.db.db
       .put(s.data.blockHash.cliqueSnapshotKey.toOpenArray, rlp.encode(s.data))
  except CatchableError as e:
    return err((errSnapshotStore,e.msg))
  result = ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
