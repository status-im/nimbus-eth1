# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[algorithm, sequtils, strformat, strutils, tables],
  eth/keys,
  ethash,
  secp256k1/abi,
  stew/objects,
  ../../nimbus/core/[chain, clique], # must be early (compilation annoyance)
  ../../nimbus/common/common,
  ../../nimbus/core/clique/[clique_desc, clique_genvote,
                            clique_helpers, clique_snapshot],
  ../../nimbus/core/clique/snapshot/[ballot, snapshot_desc],
  ../../nimbus/[config, constants],
  ./voter_samples as vs

export
  vs, snapshot_desc

const
  prngSeed = 42
    ## The `TestSpecs` sample depends on this seed,

type
  XSealKey = array[EXTRA_SEAL,byte]
  XSealValue = object
    blockNumber: uint64
    account:     string

  TesterPool* = ref object ## Pool to maintain currently active tester accounts,
                           ## mapped from textual names used in the tests below
                           ## to actual Ethereum private keys capable of signing
                           ## transactions.
    prng: uint32                       ## random state
    accounts: Table[string,PrivateKey] ## accounts table
    networkId: NetworkId
    boot: NetworkParams                ## imported Genesis configuration
    batch: seq[seq[BlockHeader]]       ## collect header chains
    chain: ChainRef

    names: Table[EthAddress,string]    ## reverse lookup for debugging
    xSeals: Table[XSealKey,XSealValue] ## collect signatures for debugging
    noisy*: bool

# ------------------------------------------------------------------------------
# Private Prng (Clique keeps generated addresses sorted)
# ------------------------------------------------------------------------------

proc posixPrngInit(state: var uint32; seed: uint32) =
  state = seed

proc posixPrngRand(state: var uint32): byte =
  ## POSIX.1-2001 example of a rand() implementation, see manual page rand(3).
  ##
  ## Clique relies on the even/odd position of an address after sorting. For
  ## address generation, the Nim PRNG was used which seems to have changed
  ## with Nim 1.6.11 (Linux, Windoes only.)
  ##
  ## The `TestSpecs` sample depends on `prngSeed` and `posixPrngRand()`.
  state = state * 1103515245 + 12345;
  let val = (state shr 16) and 32767    # mod 2^31
  (val shr 8).byte                      # Extract second byte

# ------------------------------------------------------------------------------
# Private Helpers
# ------------------------------------------------------------------------------

proc getBlockHeader(ap: TesterPool; number: BlockNumber): BlockHeader =
  ## Shortcut => db/core_db.getBlockHeader()
  doAssert ap.chain.clique.db.getBlockHeader(number, result)

proc getBlockHeader(ap: TesterPool; hash: Hash256): BlockHeader =
  ## Shortcut => db/core_db.getBlockHeader()
  doAssert ap.chain.clique.db.getBlockHeader(hash, result)

proc isZero(a: openArray[byte]): bool =
  result = true
  for w in a:
    if w != 0:
      return false

proc rand(ap: TesterPool): byte =
  ap.prng.posixPrngRand().byte

proc newPrivateKey(ap: TesterPool): PrivateKey =
  ## Roughly modelled after `random(PrivateKey,getRng()[])` with
  ## non-secure but reproducible PRNG
  var data{.noinit.}: array[SkRawSecretKeySize,byte]
  for n in 0 ..< data.len:
    data[n] = ap.rand
  # verify generated key, see keys.random(PrivateKey) from eth/keys.nim
  var dataPtr0 = cast[ptr byte](unsafeAddr data[0])
  doAssert secp256k1_ec_seckey_verify(
    secp256k1_context_no_precomp, dataPtr0) == 1
  # Convert to PrivateKey
  PrivateKey.fromRaw(data).value

proc privateKey(ap: TesterPool; account: string): PrivateKey =
  ## Return private key for given tester `account`
  if account != "":
    if account in ap.accounts:
      result = ap.accounts[account]
    else:
      result = ap.newPrivateKey
      ap.accounts[account] = result
      let address = result.toPublicKey.toCanonicalAddress
      ap.names[address] = account

# ------------------------------------------------------------------------------
# Private pretty printer call backs
# ------------------------------------------------------------------------------

proc findName(ap: TesterPool; address: EthAddress): string =
  ## Find name for a particular address
  if address notin ap.names:
    ap.names[address] = &"X{ap.names.len+1}"
  ap.names[address]

proc findSignature(ap: TesterPool; sig: openArray[byte]): XSealValue =
  ## Find a previusly registered signature
  if sig.len == XSealKey.len:
    let key = toArray(XSealKey.len,sig)
    if key in ap.xSeals:
      result = ap.xSeals[key]

proc pp(ap: TesterPool; v: BlockNonce): string =
  ## Pretty print nonce
  if v == NONCE_AUTH:
    "AUTH"
  elif v == NONCE_DROP:
    "DROP"
  else:
    &"0x{v.toHex}"

proc pp(ap: TesterPool; v: EthAddress): string =
  ## Pretty print address
  if v.isZero:
    result = "@0"
  else:
    let a = ap.findName(v)
    if a == "":
      result = &"@{v}"
    else:
      result = &"@{a}"

proc pp*(ap: TesterPool; v: openArray[EthAddress]): seq[string] =
  ## Pretty print address list
  toSeq(v).mapIt(ap.pp(it))

proc pp(ap: TesterPool; v: Blob): string =
  ## Visualise `extraData` field

  if v.len < EXTRA_VANITY + EXTRA_SEAL or
     ((v.len - (EXTRA_VANITY + EXTRA_SEAL)) mod EthAddress.len) != 0:
    result = &"0x{v.toHex}[{v.len}]"
  else:
    var data = v
    #
    # extra vanity prefix
    let vanity = data[0 ..< EXTRA_VANITY]
    data = data[EXTRA_VANITY ..< data.len]
    result = if vanity.isZero: "0u256+" else: &"{vanity.toHex}+"
    #
    # list of addresses
    if EthAddress.len + EXTRA_SEAL <= data.len:
      var glue = "["
      while EthAddress.len + EXTRA_SEAL <= data.len:
        let address = toArray(EthAddress.len,data[0 ..< EthAddress.len])
        data = data[EthAddress.len ..< data.len]
        result &= &"{glue}{ap.pp(address)}"
        glue = ","
      result &= "]+"
    #
    # signature
    let val = ap.findSignature(data)
    if val.account != "":
      result &= &"<#{val.blockNumber},{val.account}>"
    elif data.isZero:
      result &= &"<0>"
    else:
      let sig = SkSignature.fromRaw(data)
      if sig.isOk:
        result &= &"<{sig.value.toHex}>"
      else:
        result &= &"0x{data.toHex}[{data.len}]"

proc pp(ap: TesterPool; v: Vote): string =
  proc authorized(b: bool): string =
    if b: "authorise" else: "de-authorise"
  "(" &
    &"address={ap.pp(v.address)}" &
    &",signer={ap.pp(v.signer)}" &
    &",blockNumber=#{v.blockNumber}" &
    &",{authorized(v.authorize)}" & ")"

proc pp(ap: TesterPool; h: AddressHistory): string =
  toSeq(h.keys)
    .sorted
    .mapIt("#" & $it & ":" & ap.pp(h[it.u256]))
    .join(",")

proc votesList(ap: TesterPool; s: Snapshot; sep: string): string =
  proc s3Cmp(a, b: (string,string,Vote)): int =
    result = cmp(a[0], b[0])
    if result == 0:
      result = cmp(a[1], b[1])
  let votes = s.ballot.votesInternal
  votes.mapIt((ap.pp(it[0]),ap.pp(it[1]),it[2]))
    .sorted(cmp = s3Cmp)
    .mapIt(ap.pp(it[2]))
    .join(sep)

proc signersList(ap: TesterPool; s: Snapshot): string =
  ap.pp(s.ballot.authSigners).sorted.join(",")

proc pp*(ap: TesterPool; s: Snapshot; delim: string): string =
  ## Pretty print descriptor
  let
    p1 = if 0 < delim.len: delim else: ";"
    p2 = if 0 < delim.len and delim[0] == '\n': delim & ' '.repeat(7) else: ";"
  "(" &
    &"blockNumber=#{s.blockNumber}" &
    &"{p1}recents=" & "{" & ap.pp(s.recents) & "}" &
    &"{p1}signers=" & "{" & ap.signersList(s) & "}" &
    &"{p1}votes=[" & ap.votesList(s,p2) & "])"

proc pp*(ap: TesterPool; s: Snapshot; indent = 0): string =
  ## Pretty print descriptor
  let delim = if 0 < indent: "\n" & ' '.repeat(indent) else: " "
  ap.pp(s, delim)

proc pp(ap: TesterPool; v: BlockHeader; delim: string): string =
  ## Pretty print block header
  let sep = if 0 < delim.len: delim else: ";"
  &"(blockNumber=#{v.blockNumber}" &
    &"{sep}parentHash={v.parentHash}" &
    &"{sep}selfHash={v.blockHash}" &
    &"{sep}stateRoot={v.stateRoot}" &
    &"{sep}coinbase={ap.pp(v.coinbase)}" &
    &"{sep}nonce={ap.pp(v.nonce)}" &
    &"{sep}extraData={ap.pp(v.extraData)})"

proc pp(ap: TesterPool; v: BlockHeader; indent = 3): string =
  ## Pretty print block header, NL delimited, indented fields
  let delim = if 0 < indent: "\n" & ' '.repeat(indent) else: " "
  ap.pp(v, delim)

# ------------------------------------------------------------------------------
# Private: Constructor helpers
# ------------------------------------------------------------------------------

proc resetChainDb(ap: TesterPool; extraData: Blob; debug = false) =
  ## Setup new block chain with bespoke genesis
  # new genesis block
  if 0 < extraData.len:
    ap.boot.genesis.extraData = extraData

  let com = CommonRef.new(
    newCoreDbRef LegacyDbMemory,
    networkId = ap.networkId,
    params = ap.boot)
  ap.chain = newChain(com)
  com.initializeEmptyDB()
  ap.noisy = debug

proc initTesterPool(ap: TesterPool): TesterPool {.discardable.} =
  result = ap
  result.prng.posixPrngInit(prngSeed)
  result.batch = @[newSeq[BlockHeader]()]
  result.accounts = initTable[string,PrivateKey]()
  result.xSeals = initTable[XSealKey,XSealValue]()
  result.names = initTable[EthAddress,string]()
  result.resetChainDb(@[])

# ------------------------------------------------------------------------------
# Public: pretty printer support
# ------------------------------------------------------------------------------

proc say*(t: TesterPool; v: varargs[string,`$`]) =
  if t.noisy:
    stderr.write v.join & "\n"

proc sayHeaderChain*(ap: TesterPool; indent = 0): TesterPool {.discardable.} =
  result = ap
  let pfx = ' '.repeat(indent)
  var top = if 0 < ap.batch[^1].len: ap.batch[^1][^1]
            else: ap.getBlockHeader(0.u256)
  ap.say pfx, "   top header: " & ap.pp(top, 16+indent)
  while not top.blockNumber.isZero:
    top = ap.getBlockHeader(top.parentHash)
    ap.say pfx, "parent header: " &  ap.pp(top, 16+indent)

# ------------------------------------------------------------------------------
# Public: Constructor
# ------------------------------------------------------------------------------

proc newVoterPool*(networkId = GoerliNet): TesterPool =
  TesterPool(
    networkId: networkId,
    boot: networkParams(networkId)
  ).initTesterPool

# ------------------------------------------------------------------------------
# Public: getter
# ------------------------------------------------------------------------------

proc chain*(ap: TesterPool): ChainRef =
  ## Getter
  ap.chain

proc clique*(ap: TesterPool): Clique =
  ## Getter
  ap.chain.clique

proc db*(ap: TesterPool): CoreDbRef =
  ## Getter
  ap.clique.db

proc cliqueSigners*(ap: TesterPool): seq[EthAddress] =
  ## Getter
  ap.clique.cliqueSigners

proc cliqueSignersLen*(ap: TesterPool): int =
  ## Getter
  ap.clique.cliqueSignersLen

proc snapshot*(ap: TesterPool): Snapshot =
  ## Getter
  ap.clique.snapshot

proc failed*(ap: TesterPool): CliqueFailed =
  ## Getter
  ap.clique.failed

# ------------------------------------------------------------------------------
# Public: setter
# ------------------------------------------------------------------------------

proc `verifyFrom=`*(ap: TesterPool; verifyFrom: uint64) =
  ## Setter, block number where `Clique` should start
  ap.chain.verifyFrom = verifyFrom

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# clique/snapshot_test.go(62): func (ap *testerAccountPool) address(account [..]
proc address*(ap: TesterPool; account: string): EthAddress =
  ## retrieves the Ethereum address of a tester account by label, creating
  ## a new account if no previous one exists yet.
  if account != "":
    result = ap.privateKey(account).toPublicKey.toCanonicalAddress

# ------------------------------------------------------------------------------
# Public: set up & manage voter database
# ------------------------------------------------------------------------------

proc resetVoterChain*(ap: TesterPool; signers: openArray[string];
                      epoch = 0; runBack = true): TesterPool {.discardable.} =
  ## Reset the batch list for voter headers and update genesis block
  result = ap

  ap.batch = @[newSeq[BlockHeader]()]

  # clique/snapshot_test.go(384): signers := make([]common.Address, [..]
  let signers = signers.mapIt(ap.address(it)).sorted(EthAscending)

  var extraData = 0.byte.repeat(EXTRA_VANITY)

  # clique/snapshot_test.go(399): for j, signer := range signers {
  for signer in signers:
    extraData.add signer.toSeq

  # clique/snapshot_test.go(397):
  extraData.add 0.byte.repeat(EXTRA_SEAL)

  # store modified genesis block and epoch
  ap.resetChainDb(extraData, ap.noisy)
  ap.clique.cfg.epoch = epoch
  ap.clique.applySnapsMinBacklog = runBack


# clique/snapshot_test.go(415): blocks, _ := core.GenerateChain(&config, [..]
proc appendVoter*(ap: TesterPool;
                  voter: TesterVote): TesterPool {.discardable.} =
  ## Append a voter header to the block chain batch list
  result = ap

  doAssert 0 < ap.batch.len # see initTesterPool() and resetVoterChain()
  let parent = if ap.batch[^1].len == 0:
                 ap.getBlockHeader(0.u256)
               else:
                 ap.batch[^1][^1]

  let header = ap.chain.clique.cliqueGenvote(
    voter = ap.address(voter.voted),
    seal = ap.privateKey(voter.signer),
    parent = parent,
    elapsed = EthTime(100),
    voteInOk = voter.auth,
    outOfTurn = voter.noTurn,
    checkPoint = voter.checkpoint.mapIt(ap.address(it)).sorted(EthAscending))

  if 0 < voter.checkpoint.len:
    doAssert (header.blockNumber mod ap.clique.cfg.epoch).isZero

  # Register for debugging
  let
    extraLen = header.extraData.len
    extraSeal = header.extraData[extraLen - EXTRA_SEAL ..< extraLen]
  ap.xSeals[toArray(XSealKey.len,extraSeal)] = XSealValue(
    blockNumber: header.blockNumber.truncate(uint64),
    account:     voter.signer)

  if voter.newbatch:
    ap.batch.add @[]
  ap.batch[^1].add header


proc appendVoter*(ap: TesterPool;
                  voters: openArray[TesterVote]): TesterPool {.discardable.} =
  ## Append a list of voter headers to the block chain batch list
  result = ap
  for voter in voters:
    ap.appendVoter(voter)


proc commitVoterChain*(ap: TesterPool; postProcessOk = false;
                       stopFaultyHeader = false): TesterPool {.discardable.} =
  ## Write the headers from the voter header batch list to the block chain DB.
  ##
  ## If `postProcessOk` is set, an additional verification step is added at
  ## the end of each transaction.
  ##
  ## if `stopFaultyHeader` is set, the function stops immediately on error.
  ## Otherwise the offending block is removed, the rest of the batch is
  ## adjusted and applied again repeatedly.
  result = ap

  var reChainOk = false
  for n in 0 ..< ap.batch.len:
    block forLoop:

      var headers = ap.batch[n]
      while true:
        if headers.len == 0:
          break forLoop # continue with for loop

        ap.say &"*** transaction ({n}) list: [",
          headers.mapIt(&"#{it.blockNumber}").join(", "), "]"

        # Realign rest of transaction to existing block chain
        if reChainOk:
          var parent = ap.chain.clique.db.getCanonicalHead
          for i in 0 ..< headers.len:
            headers[i].parentHash = parent.blockHash
            headers[i].blockNumber = parent.blockNumber + 1
            parent = headers[i]

        # Perform transaction into the block chain
        let bodies = BlockBody().repeat(headers.len)
        if ap.chain.persistBlocks(headers,bodies) == ValidationResult.OK:
          break
        if stopFaultyHeader:
          return

        # If the offending block is the last one of the last transaction,
        # then there is nothing to do.
        let culprit =  headers.filterIt(ap.failed[0] == it.blockHash)
        doAssert culprit.len == 1
        let number = culprit[0].blockNumber
        if n + 1 == ap.batch.len and number == headers[^1].blockNumber:
          return

        # Remove offending block and try again for the rest
        ap.say "*** persistBlocks failed, omitting block #", culprit
        let prevLen = headers.len
        headers = headers.filterIt(number != it.blockNumber)
        doAssert headers.len < prevLen
        reChainOk = true

      if ap.noisy:
        ap.say "*** snapshot argument: #", headers[^1].blockNumber
        ap.sayHeaderChain(8)
        when false: # all addresses are typically pp-mappable
          ap.say "          address map: ", toSeq(ap.names.pairs)
                                            .mapIt(&"@{it[1]}:{it[0]}")
                                            .sorted
                                            .join("\n" & ' '.repeat(23))
      if postProcessOk:
        discard ap.clique.cliqueSnapshot(headers[^1])

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
