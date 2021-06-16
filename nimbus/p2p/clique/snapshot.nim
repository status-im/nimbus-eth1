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

const
   # debugging, enable with: nim c -r -d:noisy:3 ...
   noisy {.intdefine.}: int = 0
   isMainOk {.used.} = noisy > 2

import
  std/[algorithm, sequtils, strformat, strutils, tables, times],
  ../../db/[storage_types, db_chain],
  ../../utils/lru_cache,
  ./clique_cfg,
  ./clique_defs,
  ./clique_poll,
  ./ec_recover,
  chronicles,
  eth/[common, rlp, trie/db]

type
  AddressHistory = Table[BlockNumber,EthAddress]

  SnapshotData* = object
    blockNumber: BlockNumber ## truncated block num where snapshot was created
    blockHash: Hash256       ## block hash where snapshot was created
    recents: AddressHistory  ## recent signers for spam protections

    # clique/snapshot.go(58): Recents map[uint64]common.Address [..]
    ballot: CliquePoll       ## Votes => authorised signers
    debug: bool              ## debug mode

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

proc say(s: var Snapshot; v: varargs[string,`$`]) =
  ## Debugging output
  ppExceptionWrap:
    if s.data.debug:
      stderr.write "*** " & v.join & "\n"

proc getPrettyPrinters(s: var Snapshot): var PrettyPrinters =
  ## Mixin for pretty printers
  s.cfg.prettyPrint

proc pp(s: var Snapshot; h: var AddressHistory): string =
  ppExceptionWrap:
    toSeq(h.keys)
      .sorted
      .mapIt("#" & $it & ":" & s.pp(h[it.u256]))
      .join(",")

proc pp(s: var Snapshot; v: Vote): string =
  proc authorized(b: bool): string =
    if b: "authorise" else: "de-authorise"
  ppExceptionWrap:
    "(" & &"address={s.pp(v.address)}" &
          &",signer={s.pp(v.signer)}" &
          &",blockNumber={v.blockNumber}" &
          &",{authorized(v.authorize)}" & ")"

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
# Public pretty printers
# ------------------------------------------------------------------------------

proc pp*(s: var Snapshot; delim: string): string =
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

proc pp*(s: var Snapshot; indent = 0): string =
  ## Pretty print descriptor
  let delim = if 0 < indent: "\n" & ' '.repeat(indent) else: " "
  s.pp(delim)

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
# Public functions
# ------------------------------------------------------------------------------

proc setDebug*(s: var Snapshot; debug: bool) =
  ## Set debugging mode on/off
  s.data.debug = debug
  s.data.ballot.setDebug(debug)

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
  s.data.ballot.initCliquePoll(signers)

proc initSnapshot*(cfg: CliqueCfg; number: BlockNumber; hash: Hash256;
                   signers: openArray[EthAddress]; debug = true): Snapshot =
  result.initSnapshot(cfg, number, hash, signers)


proc blockNumber*(s: var Snapshot): BlockNumber =
  ## Getter
  s.data.blockNumber

# clique/snapshot.go(88): func loadSnapshot(config [..]
proc loadSnapshot*(s: var Snapshot; cfg: CliqueCfg;
           hash: Hash256): CliqueResult {.gcsafe, raises: [Defect].} =
  ## Load an existing snapshot from the database.
  try:
    let
      key = hash.cliqueSnapshotKey
      value = cfg.dbChain.db.get(key.toOpenArray)
    s.data = value.decode(SnapshotData)
    s.cfg = cfg
  except CatchableError as e:
    return err((errSnapshotLoad,e.msg))
  result = ok()


# clique/snapshot.go(104): func (s *Snapshot) store(db [..]
proc storeSnapshot*(s: var Snapshot): CliqueResult {.gcsafe,raises: [Defect].} =
  ## Insert the snapshot into the database.
  try:
    let
      key = s.data.blockHash.cliqueSnapshotKey
      value = rlp.encode(s.data)
    s.cfg.dbChain.db.put(key.toOpenArray, value)
  except CatchableError as e:
    return err((errSnapshotStore,e.msg))
  result = ok()


# clique/snapshot.go(185): func (s *Snapshot) apply(headers [..]
proc applySnapshot*(s: var Snapshot;
                    headers: openArray[BlockHeader]): CliqueResult {.
                      gcsafe, raises: [Defect,CatchableError].} =
  ## Initialises an authorization snapshot `snap` by applying the `headers`
  ## to the argument snapshot desciptor `s`.

  s.say "applySnapshot ", s.pp(headers).join("\n" & ' '.repeat(18))

  # Allow passing in no headers for cleaner code
  if headers.len == 0:
    return ok()

  # Sanity check that the headers can be applied
  if headers[0].blockNumber != s.data.blockNumber + 1:
    return err((errInvalidVotingChain,""))
  # clique/snapshot.go(191): for i := 0; i < len(headers)-1; i++ {
  for i in 0 ..< headers.len - 1:
    if headers[i+1].blockNumber != headers[i].blockNumber+1:
      return err((errInvalidVotingChain,""))

  # Iterate through the headers and create a new snapshot
  let
    start = getTime()
    logInterval = initDuration(seconds = 8)
  var
    logged = start

  s.say "applySnapshot state=", s.pp(25)

  # clique/snapshot.go(206): for i, header := range headers [..]
  for headersIndex in 0 ..< headers.len:
    let
      # headersIndex => also used for logging at the end of this loop
      header = headers[headersIndex]
      number = header.blockNumber

    s.say "applySnapshot processing #", number

    # Remove any votes on checkpoint blocks
    if (number mod s.cfg.epoch) == 0:
      # Note that the correctness of the authorised accounts list is verified in
      #   clique/clique.verifyCascadingFields(),
      #   see clique/clique.go(355): if number%c.config.Epoch == 0 {
      # This means, the account list passed with the epoch header is verified
      # to be the same as the one we already have.
      #
      # clique/snapshot.go(210): snap.Votes = nil
      s.data.ballot.flushVotes
      s.say "applySnapshot epoch => reset, state=", s.pp(41)

    # Delete the oldest signer from the recent list to allow it signing again
    block:
      let limit = s.data.ballot.authSignersThreshold.u256
      if limit <= number:
        s.data.recents.del(number - limit)

    # Resolve the authorization key and check against signers
    let signer = ? s.cfg.signatures.getEcRecover(header)
    s.say "applySnapshot signer=", s.pp(signer)

    if not s.data.ballot.isAuthSigner(signer):
      s.say "applySnapshot signer not authorised => fail ", s.pp(29)
      return err((errUnauthorizedSigner,""))

    for recent in s.data.recents.values:
      if recent == signer:
        s.say "applySnapshot signer recently seen ", s.pp(signer)
        return err((errRecentlySigned,""))
    s.data.recents[number] = signer

    # Header authorized, discard any previous vote from the signer
    # clique/snapshot.go(233): for i, vote := range snap.Votes {
    s.data.ballot.delVote(signer = signer, address = header.coinbase)

    # Tally up the new vote from the signer
    # clique/snapshot.go(244): var authorize bool
    var authOk = false
    if header.nonce == NONCE_AUTH:
      authOk = true
    elif header.nonce != NONCE_DROP:
      return err((errInvalidVote,""))
    let vote = Vote(address:     header.coinbase,
                    signer:      signer,
                    blockNumber: number,
                    authorize:   authOk)
    s.say "applySnapshot calling addVote ", s.pp(vote)
    # clique/snapshot.go(253): if snap.cast(header.Coinbase, authorize) {
    s.data.ballot.addVote(vote)

    # clique/snapshot.go(269): if limit := uint64(len(snap.Signers)/2 [..]
    if s.data.ballot.authSignersShrunk:
      # Signer list shrunk, delete any leftover recent caches
      let limit = s.data.ballot.authSignersThreshold.u256
      if limit <= number:
        # Pop off least block number from the list
        let item = number - limit
        s.say "will delete recent item #", item, " (", number, "-", limit,
          ") from recents={", s.pp(s.data.recents), "}"
        s.data.recents.del(item)

    s.say "applySnapshot state=", s.pp(25)

    # If we're taking too much time (ecrecover), notify the user once a while
    if logInterval < logged - getTime():
      info "Reconstructing voting history",
        processed = headersIndex,
        total = headers.len,
        elapsed = start - getTime()
      logged = getTime()

  let sinceStart = start - getTime()
  if logInterval < sinceStart:
    info "Reconstructed voting history",
      processed = headers.len,
      elapsed = sinceStart

  # clique/snapshot.go(303): snap.Number += uint64(len(headers))
  s.data.blockNumber += headers.len.u256
  s.data.blockHash = headers[^1].blockHash
  result = ok()


proc validVote*(s: var Snapshot; address: EthAddress; authorize: bool): bool =
  ## Returns `true` if voting makes sense, at all.
  s.data.ballot.validVote(address, authorize)

proc recent*(s: var Snapshot; address: EthAddress): Result[BlockNumber,void] =
  ## Return `BlockNumber` for `address` argument (if any)
  for (number,recent) in s.data.recents.pairs:
    if recent == address:
      return ok(number)
  return err()

proc signersThreshold*(s: var Snapshot): int =
  ## Forward to `CliquePoll`: Minimum number of authorised signers needed.
  s.data.ballot.authSignersThreshold

proc isSigner*(s: var Snapshot; address: EthAddress): bool =
  ## Checks whether argukment ``address` is in signers list
  s.data.ballot.isAuthSigner(address)

proc signers*(s: var Snapshot): seq[EthAddress] =
  ## Retrieves the sorted list of authorized signers
  s.data.ballot.authSigners


# clique/snapshot.go(319): func (s *Snapshot) inturn(number [..]
proc inTurn*(s: var Snapshot; number: BlockNumber, signer: EthAddress): bool =
  ## Returns `true` if a signer at a given block height is in-turn or not.
  let ascSignersList = s.data.ballot.authSigners
  for offset in 0 ..< ascSignersList.len:
    if ascSignersList[offset] == signer:
      return (number mod ascSignersList.len.u256) == offset.u256

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
