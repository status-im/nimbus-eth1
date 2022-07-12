# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[random, sequtils, strformat, strutils, tables, times],
  ../../nimbus/[config, chain_config, constants, genesis],
  ../../nimbus/db/db_chain,
  ../../nimbus/p2p/[chain,
                    clique,
                    clique/clique_desc,
                    clique/clique_genvote,
                    clique/clique_helpers,
                    clique/clique_snapshot,
                    clique/snapshot/snapshot_desc],
  ./voter_samples as vs,
  eth/[common, keys, p2p, rlp, trie/db],
  ethash,
  secp256k1/abi,
  stew/objects

export
  vs, snapshot_desc

const
  prngSeed = 42

type
  XSealKey = array[EXTRA_SEAL,byte]
  XSealValue = object
    blockNumber: uint64
    account:     string

  TesterPool* = ref object ## Pool to maintain currently active tester accounts,
                           ## mapped from textual names used in the tests below
                           ## to actual Ethereum private keys capable of signing
                           ## transactions.
    prng: Rand
    accounts: Table[string,PrivateKey] ## accounts table
    networkId: NetworkId
    boot: NetworkParams                ## imported Genesis configuration
    batch: seq[seq[BlockHeader]]       ## collect header chains
    chain: Chain

    names: Table[EthAddress,string]    ## reverse lookup for debugging
    xSeals: Table[XSealKey,XSealValue] ## collect signatures for debugging

# ------------------------------------------------------------------------------
# Private Helpers
# ------------------------------------------------------------------------------

proc getBlockHeader(ap: TesterPool; number: BlockNumber): BlockHeader =
  ## Shortcut => db/db_chain.getBlockHeader()
  doAssert ap.chain.clique.db.getBlockHeader(number, result)

proc getBlockHeader(ap: TesterPool; hash: Hash256): BlockHeader =
  ## Shortcut => db/db_chain.getBlockHeader()
  doAssert ap.chain.clique.db.getBlockHeader(hash, result)

proc isZero(a: openArray[byte]): bool =
  result = true
  for w in a:
    if w != 0:
      return false

proc rand(ap: TesterPool): byte =
  ap.prng.rand(255).byte

proc newPrivateKey(ap: TesterPool): PrivateKey =
  ## Roughly modelled after `random(PrivateKey,getRng()[])` with
  ## non-secure but reproducible PRNG
  var data{.noinit.}: array[SkRawSecretKeySize,byte]
  for n in 0 ..< data.len:
    data[n] = ap.rand
  # verify generated key, see keys.random(PrivateKey) from eth/keys.nim
  var dataPtr0 = cast[ptr cuchar](unsafeAddr data[0])
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

proc ppNonce(ap: TesterPool; v: BlockNonce): string =
  ## Pretty print nonce
  if v == NONCE_AUTH:
    "AUTH"
  elif v == NONCE_DROP:
    "DROP"
  else:
    &"0x{v.toHex}"

proc ppAddress(ap: TesterPool; v: EthAddress): string =
  ## Pretty print address
  if v.isZero:
    result = "@0"
  else:
    let a = ap.findName(v)
    if a == "":
      result = &"@{v}"
    else:
      result = &"@{a}"

proc ppExtraData(ap: TesterPool; v: Blob): string =
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
        result &= &"{glue}{ap.ppAddress(address)}"
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

proc ppBlockHeader(ap: TesterPool; v: BlockHeader; delim: string): string =
  ## Pretty print block header
  let sep = if 0 < delim.len: delim else: ";"
  &"(blockNumber=#{v.blockNumber.truncate(uint64)}" &
    &"{sep}parentHash={v.parentHash}" &
    &"{sep}selfHash={v.blockHash}" &
    &"{sep}stateRoot={v.stateRoot}" &
    &"{sep}coinbase={ap.ppAddress(v.coinbase)}" &
    &"{sep}nonce={ap.ppNonce(v.nonce)}" &
    &"{sep}extraData={ap.ppExtraData(v.extraData)})"

# ------------------------------------------------------------------------------
# Private: Constructor helpers
# ------------------------------------------------------------------------------

proc initPrettyPrinters(pp: var PrettyPrinters; ap: TesterPool) =
  pp.nonce =       proc(v:BlockNonce):            string = ap.ppNonce(v)
  pp.address =     proc(v:EthAddress):            string = ap.ppAddress(v)
  pp.extraData =   proc(v:Blob):                  string = ap.ppExtraData(v)
  pp.blockHeader = proc(v:BlockHeader; d:string): string = ap.ppBlockHeader(v,d)

proc resetChainDb(ap: TesterPool; extraData: Blob; debug = false) =
  ## Setup new block chain with bespoke genesis
  let chainDB = newBaseChainDB(
    newMemoryDb(),
    id = ap.networkId,
    params = ap.boot)
  ap.chain = newChain(chainDB)
  ap.chain.clique.db.populateProgress

  # new genesis block
  if 0 < extraData.len:
    chainDB.genesis.extraData = extraData
  initializeEmptyDB(chainDB)
  # fine tune Clique descriptor
  ap.chain.clique.cfg.debug = debug
  ap.chain.clique.cfg.prettyPrint.initPrettyPrinters(ap)

proc initTesterPool(ap: TesterPool): TesterPool {.discardable.} =
  result = ap
  result.prng = initRand(prngSeed)
  result.batch = @[newSeq[BlockHeader]()]
  result.accounts = initTable[string,PrivateKey]()
  result.xSeals = initTable[XSealKey,XSealValue]()
  result.names = initTable[EthAddress,string]()
  result.resetChainDb(@[])

# ------------------------------------------------------------------------------
# Public: pretty printer support
# ------------------------------------------------------------------------------

proc getPrettyPrinters*(t: TesterPool): var PrettyPrinters =
  ## Mixin for pretty printers, see `clique/clique_cfg.pp()`
  t.chain.clique.cfg.prettyPrint

proc say*(t: TesterPool; v: varargs[string,`$`]) =
  if t.chain.clique.cfg.debug:
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

proc chain*(ap: TesterPool): auto {.inline.} =
  ## Getter
  ap.chain

proc clique*(ap: TesterPool): auto {.inline.} =
  ## Getter
  ap.chain.clique

proc db*(ap: TesterPool): auto {.inline.} =
  ## Getter
  ap.clique.db

proc debug*(ap: TesterPool): auto {.inline.} =
  ## Getter
  ap.clique.cfg.debug

proc cliqueSigners*(ap: TesterPool): auto {.inline.} =
  ## Getter
  ap.clique.cliqueSigners

proc cliqueSignersLen*(ap: TesterPool): auto {.inline.} =
  ## Getter
  ap.clique.cliqueSignersLen

proc snapshot*(ap: TesterPool): auto {.inline.} =
  ## Getter
  ap.clique.snapshot

proc failed*(ap: TesterPool): CliqueFailed {.inline.} =
  ## Getter
  ap.clique.failed

# ------------------------------------------------------------------------------
# Public: setter
# ------------------------------------------------------------------------------

proc `debug=`*(ap: TesterPool; debug: bool) {.inline,} =
  ## Set debugging mode on/off
  ap.clique.cfg.debug = debug

proc `verifyFrom=`*(ap: TesterPool; verifyFrom: uint64) {.inline.} =
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
  ap.resetChainDb(extraData, ap.debug )
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
    elapsed = initDuration(seconds = 100),
    voteInOk = voter.auth,
    outOfTurn = voter.noTurn,
    checkPoint = voter.checkpoint.mapIt(ap.address(it)).sorted(EthAscending))

  if 0 < voter.checkpoint.len:
    doAssert (header.blockNumber mod ap.clique.cfg.epoch) == 0

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

      if ap.debug:
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
