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
  ../../nimbus/[config, chain_config, constants, genesis, utils],
  ../../nimbus/db/db_chain,
  ../../nimbus/p2p/clique,
  ../../nimbus/p2p/clique/clique_utils,
  ./voter_samples as vs,
  eth/[common, keys, p2p, rlp, trie/db],
  ethash,
  secp256k1_abi,
  stew/objects

export
  vs

const
  prngSeed = 42
  # genesisTemplate = "../customgenesis/berlin2000.json"

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
    boot: CustomGenesis                ## imported Genesis configuration
    batch: seq[seq[BlockHeader]]       ## collect header chains
    engine: Clique

    names: Table[EthAddress,string]    ## reverse lookup for debugging
    xSeals: Table[XSealKey,XSealValue] ## collect signatures for debugging
    debug: bool                        ## debuggin mode for sub-systems

# ------------------------------------------------------------------------------
# Private Helpers
# ------------------------------------------------------------------------------

proc chain(ap: TesterPool): auto =
  ## Getter
  ap.engine.db

proc getBlockHeader(ap: TesterPool; number: BlockNumber): BlockHeader =
  ## Shortcut => db/db_chain.getBlockHeader()
  doAssert ap.chain.getBlockHeader(number, result)

proc getBlockHeader(ap: TesterPool; hash: Hash256): BlockHeader =
  ## Shortcut => db/db_chain.getBlockHeader()
  doAssert ap.chain.getBlockHeader(hash, result)

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

proc resetChainDb(ap: TesterPool; extraData: Blob) =
  ## Setup new block chain with bespoke genesis
  ap.engine.db = BaseChainDB(db: newMemoryDb(), config: ap.boot.config)
  ap.engine.db.populateProgress
  # new genesis block
  var g = ap.boot.genesis
  if 0 < extraData.len:
    g.extraData = extraData
  g.commit(ap.engine.db)

# ------------------------------------------------------------------------------
# Private pretty printer call backs
# ------------------------------------------------------------------------------

proc findName(ap: TesterPool; address: EthAddress): string =
  ## Find name for a particular address
  if address in ap.names:
    return ap.names[address]

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
    &"{sep}selfHash={v.hash}" &
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

proc initTesterPool(ap: TesterPool): TesterPool {.discardable.} =
  result = ap
  result.prng = initRand(prngSeed)
  result.batch = @[newSeq[BlockHeader]()]
  result.accounts = initTable[string,PrivateKey]()
  result.xSeals = initTable[XSealKey,XSealValue]()
  result.names = initTable[EthAddress,string]()
  result.engine = BaseChainDB(
    db: newMemoryDb(),
    config: ap.boot.config).newCliqueCfg.newClique
  result.engine.debug = false
  result.engine.cfg.prettyPrint.initPrettyPrinters(result)
  result.resetChainDb(@[])

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getPrettyPrinters*(t: TesterPool): var PrettyPrinters =
  ## Mixin for pretty printers, see `clique/clique_cfg.pp()`
  t.engine.cfg.prettyPrint

proc setDebug*(ap: TesterPool; debug=true): TesterPool {.inline,discardable,} =
  ## Set debugging mode on/off
  result = ap
  ap.debug = debug
  ap.engine.debug = debug

proc say*(t: TesterPool; v: varargs[string,`$`]) =
  if t.debug:
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


# clique/snapshot_test.go(62): func (ap *testerAccountPool) address(account [..]
proc address*(ap: TesterPool; account: string): EthAddress =
  ## retrieves the Ethereum address of a tester account by label, creating
  ## a new account if no previous one exists yet.
  if account != "":
    result = ap.privateKey(account).toPublicKey.toCanonicalAddress


# clique/snapshot_test.go(49): func (ap *testerAccountPool) [..]
proc checkpoint*(ap: TesterPool;
                header: var BlockHeader; signers: openArray[string]) =
  ## creates a Clique checkpoint signer section from the provided list
  ## of authorized signers and embeds it into the provided header.
  header.extraData.setLen(EXTRA_VANITY)
  header.extraData.add signers
    .mapIt(ap.address(it))
    .sorted(EthAscending)
    .mapIt(toSeq(it))
    .concat
  header.extraData.add 0.byte.repeat(EXTRA_SEAL)


# clique/snapshot_test.go(77): func (ap *testerAccountPool) sign(header n[..]
proc sign*(ap: TesterPool; header: var BlockHeader; signer: string) =
  ## sign calculates a Clique digital signature for the given block and embeds
  ## it back into the header.
  #
  # Sign the header and embed the signature in extra data
  let
    hashData = header.hashSealHeader.data
    signature = ap.privateKey(signer).sign(SkMessage(hashData)).toRaw
    extraLen = header.extraData.len
  header.extraData.setLen(extraLen -  EXTRA_SEAL)
  header.extraData.add signature
  #
  # Register for debugging
  ap.xSeals[signature] = XSealValue(
    blockNumber: header.blockNumber.truncate(uint64),
    account:     signer)


proc snapshot*(ap: TesterPool; number: BlockNumber; hash: Hash256;
               parent: openArray[BlockHeader]): auto =
  ## Call p2p/clique.snapshotInternal()
  if ap.debug:
    var header = ap.getBlockHeader(number)
    ap.say "*** snapshot argument: #", number
    ap.sayHeaderChain(8)
    when false: # all addresses are typically pp-mappable
      ap.say "          address map: ", toSeq(ap.names.pairs)
                                          .mapIt(&"@{it[1]}:{it[0]}")
                                          .sorted
                                          .join("\n" & ' '.repeat(23))

  ap.engine.snapshot(number, hash, parent)

proc clique*(ap: TesterPool): Clique =
  ## Getter
  ap.engine

# ------------------------------------------------------------------------------
# Public: Constructor
# ------------------------------------------------------------------------------

proc newVoterPool*(customGenesis: CustomGenesis): TesterPool =
  TesterPool(boot: customGenesis).initTesterPool

proc newVoterPool*(id: NetworkId): TesterPool =
  CustomGenesis(
    config: chainConfig(id),
    genesis: defaultGenesisBlockForNetwork(id)).newVoterPool

proc newVoterPool*(genesisTemplate = ""): TesterPool =
  if genesisTemplate == "":
    return getConfiguration().net.networkId.newVoterPool

  # Find genesis block from template
  new result
  doAssert genesisTemplate.loadCustomGenesis(result.boot)
  result.initTesterPool

# ------------------------------------------------------------------------------
# Public: set up & manage voter database
# ------------------------------------------------------------------------------

proc setVoterAccount*(ap: TesterPool; account: string;
                      prvKey: PrivateKey): TesterPool {.discardable.} =
  ## Manually define/import account
  result = ap
  ap.accounts[account] = prvKey
  let address = prvKey.toPublicKey.toCanonicalAddress
  ap.names[address] = account


proc resetVoterChain*(ap: TesterPool; signers: openArray[string];
                      epoch = 0): TesterPool {.discardable.} =
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
  ap.resetChainDb(extraData)
  ap.engine.cfg.epoch = epoch.uint


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

  var header = BlockHeader(
    parentHash:  parent.hash,
    ommersHash:  EMPTY_UNCLE_HASH,
    stateRoot:   parent.stateRoot,
    timestamp:   parent.timestamp + initDuration(seconds = 10),
    txRoot:      BLANK_ROOT_HASH,
    receiptRoot: BLANK_ROOT_HASH,
    blockNumber: parent.blockNumber + 1,
    gasLimit:    parent.gasLimit,
    #
    # clique/snapshot_test.go(417): gen.SetCoinbase(accounts.address( [..]
    coinbase:    ap.address(voter.voted),
    #
    # clique/snapshot_test.go(418): if tt.votes[j].auth {
    nonce:       if voter.auth: NONCE_AUTH else: NONCE_DROP,
    #
    # clique/snapshot_test.go(436): header.Difficulty = diffInTurn [..]
    difficulty:  DIFF_INTURN,  # Ignored, we just need a valid number
    #
    extraData:   0.byte.repeat(EXTRA_VANITY + EXTRA_SEAL))

  # clique/snapshot_test.go(432): if auths := tt.votes[j].checkpoint; [..]
  if 0 < voter.checkpoint.len:
    doAssert (header.blockNumber mod ap.engine.cfg.epoch) == 0
    ap.checkpoint(header,voter.checkpoint)

  # Generate the signature, embed it into the header and the block
  ap.sign(header, voter.signer)

  if voter.newbatch:
    ap.batch.add @[]
  ap.batch[^1].add header


proc appendVoter*(ap: TesterPool;
                  voters: openArray[TesterVote]): TesterPool {.discardable.} =
  ## Append a list of voter headers to the block chain batch list
  result = ap
  for voter in voters:
    ap.appendVoter(voter)


proc commitVoterChain*(ap: TesterPool): TesterPool {.discardable.} =
  ## Write the headers from the voter header batch list to the block chain DB
  result = ap

  # Create a pristine blockchain with the genesis injected
  for headers in ap.batch:
    if 0 < headers.len:
      doAssert ap.chain.getCanonicalHead.blockNumber < headers[0].blockNumber

      # see p2p/chain.persistBlocks()
      ap.chain.highestBlock = headers[^1].blockNumber
      let transaction = ap.chain.db.beginTransaction()
      for i in 0 ..< headers.len:
        let header = headers[i]

        discard ap.chain.persistHeaderToDb(header)
        doAssert ap.chain.getCanonicalHead().blockHash == header.blockHash

        discard ap.chain.persistTransactions(header.blockNumber, @[])
        discard ap.chain.persistReceipts(@[])
        ap.chain.currentBlock = header.blockNumber
      transaction.commit()


proc topVoterHeader*(ap: TesterPool): BlockHeader =
  ## Get top header from voter batch list
  doAssert 0 < ap.batch.len # see initTesterPool() and resetVoterChain()
  if 0 < ap.batch[^1].len:
    result = ap.batch[^1][^1]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
