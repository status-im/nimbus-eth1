# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  chronicles,
  metrics,
  chronos/timer,
  std/[os, strformat, strutils],
  stew/io2,
  ./config,
  ./common/common,
  ./core/[block_import, chain],
  ./db/era1_db,
  beacon_chain/era_db,
  beacon_chain/networking/network_metadata,
  beacon_chain/spec/[forks, helpers],
  ./beacon/payload_conv

declareGauge nec_import_block_number,
  "Latest imported block number"

declareCounter nec_imported_blocks,
  "Blocks processed during import"

declareCounter nec_imported_transactions,
  "Transactions processed during import"

declareCounter nec_imported_gas,
  "Gas processed during import"

var running {.volatile.} = true

proc latestEraFile*(eraDir: string, cfg: RuntimeConfig): Result[(string, Era), string] =
  ## Find the latest era file in the era directory.
  var
    latestEra = 0
    latestEraFile = ""

  try:
    for kind, obj in walkDir eraDir:
      let (_, name, _) = splitFile(obj)
      let parts = name.split('-')
      if parts.len() == 3 and parts[0] == cfg.CONFIG_NAME:
        let era =
          try:
            parseInt(parts[1])
          except ValueError:
            return err("Invalid era number")
        if era > latestEra:
          latestEra = era
          latestEraFile = obj
  except OSError as e:
    return err(e.msg)

  if latestEraFile == "":
    err("No valid era files found")
  else:
    ok((latestEraFile, Era(latestEra)))

proc loadHistoricalRootsFromEra*(
    eraDir: string, cfg: RuntimeConfig
): Result[(HashList[Eth2Digest, Limit HISTORICAL_ROOTS_LIMIT], HashList[HistoricalSummary, Limit HISTORICAL_ROOTS_LIMIT], Slot), string] =
  ## Load the historical_summaries from the latest era file.
  let
    (latestEraFile, latestEra) = ?latestEraFile(eraDir, cfg)
    f = ?EraFile.open(latestEraFile)
    slot = start_slot(latestEra)
  var bytes: seq[byte]

  ?f.getStateSSZ(slot, bytes)

  if bytes.len() == 0:
    return err("State not found")

  let state =
    try:
      newClone(readSszForkedHashedBeaconState(cfg, slot, bytes))
    except SerializationError as exc:
      return err("Unable to read state: " & exc.msg)

  withState(state[]):
    when consensusFork >= ConsensusFork.Capella:
      return ok((forkyState.data.historical_roots, forkyState.data.historical_summaries, slot+8192))
    else:
      return ok((forkyState.data.historical_roots, HashList[HistoricalSummary, Limit HISTORICAL_ROOTS_LIMIT](), slot+8192))

proc getBlockFromEra*(
    db: EraDB, historical_roots: openArray[Eth2Digest], historical_summaries: openArray[HistoricalSummary], slot: Slot, cfg: RuntimeConfig): Opt[ForkedTrustedSignedBeaconBlock] =
  
  let fork = cfg.consensusForkAtEpoch(slot.epoch)
  result.ok(ForkedTrustedSignedBeaconBlock(kind: fork))
  withBlck(result.get()):
    type T = type(forkyBlck)
    forkyBlck = db.getBlock(
      historical_roots,
      historical_summaries,
      slot,
      Opt[Eth2Digest].err(),
      T
    ).valueOr:
      result.err()
      return

proc getTxs*(txs: seq[bellatrix.Transaction]): seq[common.Transaction] =
  result = newSeqOfCap[common.Transaction](txs.len)
  for tx in txs:
    try:
      result.add(rlp.decode(tx.asSeq(), common.Transaction))
    except RlpError:
      return @[]

proc getWithdrawals*(x: seq[capella.Withdrawal]): seq[common.Withdrawal] =
  result = newSeqOfCap[common.Withdrawal](x.len)
  for w in x:
    result.add(common.Withdrawal(
      index: w.index,
      validatorIndex: w.validator_index,
      address: EthAddress(w.address.data),
      amount: uint64(w.amount)
    ))

proc getEth1Block*(blck: ForkedTrustedSignedBeaconBlock): EthBlock =
  ## Convert a beacon block to an eth1 block.
  withBlck(blck):
    when consensusFork >= ConsensusFork.Bellatrix:

      let
        payload = forkyBlck.message.body.execution_payload
        txs = getTxs(payload.transactions.asSeq())
        ethWithdrawals = 
          when consensusFork >= ConsensusFork.Capella:
            Opt.some(getWithdrawals(payload.withdrawals.asSeq()))
          else:
            Opt.none(seq[common.Withdrawal])
        withdrawalRoot = 
          when consensusFork >= ConsensusFork.Capella:
            Opt.some(calcWithdrawalsRoot(ethWithdrawals.get()))
          else:
            Opt.none(common.Hash256)
        blobGasUsed =
          when consensusFork >= ConsensusFork.Deneb:
            Opt.some(payload.blob_gas_used)
          else:
            Opt.none(uint64)
        excessBlobGas =
          when consensusFork >= ConsensusFork.Deneb:
            Opt.some(payload.excess_blob_gas)
          else:
            Opt.none(uint64)
        parentBeaconBlockRoot =
          when consensusFork >= ConsensusFork.Deneb:
            Opt.some(forkyBlck.message.parent_root)
          else:
            Opt.none(common.Hash256)

      let
        header = BlockHeader(
          parentHash: payload.parent_hash,
          ommersHash: EMPTY_UNCLE_HASH,
          coinbase: EthAddress(payload.fee_recipient.data),
          stateRoot: payload.state_root,
          txRoot: calcTxRoot(txs),
          receiptsRoot: payload.receipts_root,
          logsBloom: BloomFilter(payload.logs_bloom.data),
          difficulty: 0.u256,
          number: payload.block_number,
          gasLimit: GasInt(payload.gas_limit),
          gasUsed: GasInt(payload.gas_used),
          timestamp: EthTime(payload.timestamp),
          extraData: payload.extra_data.asSeq(),
          mixHash: payload.prev_randao,
          nonce: default(BlockNonce),
          baseFeePerGas: Opt.some(payload.base_fee_per_gas),
          withdrawalsRoot: withdrawalRoot,
          blobGasUsed: blobGasUsed,
          excessBlobGas: excessBlobGas,
          parentBeaconBlockRoot: parentBeaconBlockRoot
        )
      return EthBlock(
        header: header,
        transactions: txs,
        uncles: @[],
        withdrawals: ethWithdrawals
      )

func shortLog(a: timer.Duration, parts = int.high): string {.inline.} =
  ## Returns string representation of Duration ``a`` as nanoseconds value.
  var
    res = ""
    v = a.nanoseconds()
    parts = parts

  template f(n: string, T: Duration) =
    if v >= T.nanoseconds():
      res.add($(uint64(v div T.nanoseconds())))
      res.add(n)
      v = v mod T.nanoseconds()
      dec parts
      if v == 0 or parts <= 0:
        return res

  f("w", Week)
  f("d", Day)
  f("h", Hour)
  f("m", Minute)
  f("s", Second)
  f("ms", Millisecond)
  f("us", Microsecond)
  f("ns", Nanosecond)

  res

proc importBlocks*(conf: NimbusConf, com: CommonRef) =
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    running = false

  setControlCHook(controlCHandler)

  let
    start = com.db.getSavedStateBlockNumber() + 1
    chain = com.newChain()

  template boolFlag(flags, b): PersistBlockFlags =
    if b:
      flags
    else:
      {}

  var
    imported = 0'u64
    importedSlot = 
      if conf.csvStats.isSome:
        try:
          let file = readFile(conf.csvStats.get())
          let lines = file.splitLines()
          lines[lines.len-2].split(",")[2].parseInt().uint64
        except:
          1'u64
      else:
        1'u64
    gas = GasInt(0)
    txs = 0
    time0 = Moment.now()
    csv =
      if conf.csvStats.isSome:
        try:
          let f = open(conf.csvStats.get(), fmAppend)
          let pos = f.getFileSize()
          if pos == 0:
            f.writeLine("block_number,blocks,slot,txs,gas,time")
          f
        except IOError as exc:
          error "Could not open statistics output file",
            file = conf.csvStats, err = exc.msg
          quit(QuitFailure)
      else:
        File(nil)
    flags =
      boolFlag({PersistBlockFlag.NoValidation}, conf.noValidation) +
      boolFlag({PersistBlockFlag.NoFullValidation}, not conf.fullValidation) +
      boolFlag(NoPersistBodies, not conf.storeBodies) +
      boolFlag({PersistBlockFlag.NoPersistReceipts}, not conf.storeReceipts)
    clConfig = 
      if conf.networkId == HoleskyNet:
        getMetadataForNetwork("holesky")
      elif conf.networkId == SepoliaNet:
        getMetadataForNetwork("sepolia")
      elif conf.networkId == MainNet:
        getMetadataForNetwork("mainnet")
      else:
        error "Unsupported network", network = conf.networkId
        quit(QuitFailure)
    genesis_validators_root = 
      if conf.networkId == MainNet:
        Eth2Digest.fromHex(
          "0x4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95") # Mainnet Validators Root
      elif conf.networkId == HoleskyNet:
        Eth2Digest.fromHex(
          "0x9143aa7c615a7f7115e2b6aac319c03529df8242ae705fba9df39b79c59fa8b1") # Holesky Validators Root
      elif conf.networkId == SepoliaNet:
        Eth2Digest.fromHex(
          "0xd8ea171f3c94aea21ebc42a1ed61052acf3f9209c00e4efbaaddac09ed9b8078") # Sepolia Validators Root
      else:
        error "Unsupported network", network = conf.networkId
        quit(QuitFailure)
    blocks: seq[EthBlock]

  defer:
    if csv != nil:
      close(csv)

  nec_import_block_number.set(start.int64)

  template blockNumber(): uint64 =
    start + imported

  func f(value: float): string =
      try:
        &"{value:4.3f}"
      except ValueError:
        raiseAssert "valid fmt string"

  template process() =
    let
      time1 = Moment.now()
      statsRes = chain.persistBlocks(blocks, flags)
    if statsRes.isErr():
      error "Failed to persist blocks", error = statsRes.error
      quit(QuitFailure)

    txs += statsRes[].txs
    gas += statsRes[].gas
    let
      time2 = Moment.now()
      diff1 = (time2 - time1).nanoseconds().float / 1000000000
      diff0 = (time2 - time0).nanoseconds().float / 1000000000

    info "Imported blocks",
      blockNumber,
      blocks = imported,
      txs,
      mgas = f(gas.float / 1000000),
      bps = f(blocks.len.float / diff1),
      tps = f(statsRes[].txs.float / diff1),
      mgps = f(statsRes[].gas.float / 1000000 / diff1),
      avgBps = f(imported.float / diff0),
      avgTps = f(txs.float / diff0),
      avgMGps = f(gas.float / 1000000 / diff0),
      elapsed = shortLog(time2 - time0, 3)

    metrics.set(nec_import_block_number, int64(blockNumber))
    nec_imported_blocks.inc(blocks.len)
    nec_imported_transactions.inc(statsRes[].txs)
    nec_imported_gas.inc(statsRes[].gas)

    if csv != nil:
      # In the CSV, we store a line for every chunk of blocks processed so
      # that the file can meaningfully be appended to when restarting the
      # process - this way, each sample is independent
      try:
        csv.writeLine(
          [
            $blockNumber,
            $blocks.len,
            $importedSlot,
            $statsRes[].txs,
            $statsRes[].gas,
            $(time2 - time1).nanoseconds(),
          ].join(",")
        )
        csv.flushFile()
      except IOError as exc:
        warn "Could not write csv", err = exc.msg
    blocks.setLen(0)

  ## ##################################################### 
  ##                                                
  ##   Networks with pre-merge and post-merge history      
  ##
  ## #####################################################
  if isDir(conf.era1Dir.string):
    doAssert conf.networkId == MainNet or conf.networkId == SepoliaNet, "Only mainnet/sepolia era1 current supported"

    let
      # TODO the merge block number could be fetched from the era1 file instead,
      #      specially if the accumulator is added to the chain metadata
      lastEra1Block = 
        if conf.networkId == MainNet:
          15537393'u64                          # Mainnet
        else:
          1450409'u64                           # Sepolia
      firstSlotAfterMerge = 
        if conf.networkId == MainNet:
          4700013'u64                          # Mainnet
        else:
          115193'u64                           # Sepolia

    if start <= lastEra1Block:
      notice "Importing era1 archive",
        start, dataDir = conf.dataDir.string, era1Dir = conf.era1Dir.string

      let db = 
        if conf.networkId == MainNet:
          Era1DbRef.init(conf.era1Dir.string, "mainnet").expect("Era files present") # Mainnet
        else:
          Era1DbRef.init(conf.era1Dir.string, "sepolia").expect("Era files present") # Sepolia
      defer:
        db.dispose()

      while running and imported < conf.maxBlocks and blockNumber <= lastEra1Block:
        var blk = db.getEthBlock(blockNumber).valueOr:
          error "Could not load block from era1", blockNumber, error
          break

        imported += 1
        blocks.add move(blk)

        if blocks.lenu64 mod conf.chunkSize == 0:
          process()

      if blocks.len > 0:
        process() # last chunk, if any
    
    if start > lastEra1Block:
      doAssert isDir(conf.eraDir.string), "Era directory not found"

      notice "Importing era archive",
        start, dataDir = conf.dataDir.string, eraDir = conf.eraDir.string

      let
        eraDB = EraDB.new(
          clConfig.cfg, conf.eraDir.string, genesis_validators_root
        )
        (historical_roots, historical_summaries, endSlot) = loadHistoricalRootsFromEra(
          conf.eraDir.string, clConfig.cfg
        ).valueOr:
          error "Error loading historical summaries", error
          quit QuitFailure
      
      if importedSlot < firstSlotAfterMerge: # if resuming import we do not update the slot
        importedSlot = firstSlotAfterMerge

      while running and imported < conf.maxBlocks and importedSlot < endSlot:
        var clblock = getBlockFromEra(
          eraDB, historical_roots.asSeq(), historical_summaries.asSeq(), Slot(importedSlot), clConfig.cfg
        )
        if clblock.isSome:
          blocks.add getEth1Block(clblock.get())
          imported += 1
        
        importedSlot += 1
        if blocks.lenu64 mod conf.chunkSize == 0:
          process()
      
      if blocks.len > 0:
        process()

  ## ################################################
  ##                                                
  ##      Networks with not pre-merge history       
  ##
  ## ################################################
  if isDir(conf.eraDir.string) and conf.networkId == HoleskyNet:
    
    let
      eraDB = EraDB.new(
        clConfig.cfg, conf.eraDir.string, genesis_validators_root
      )
      (historical_roots, historical_summaries, endSlot) = loadHistoricalRootsFromEra(
        conf.eraDir.string, clConfig.cfg
      ).valueOr:
        error "Error loading historical summaries", error
        quit QuitFailure

    if importedSlot <= endSlot:
      notice "Importing era archive HoleskyNet",
        importedSlot, dataDir = conf.dataDir.string, eraDir = conf.eraDir.string

      while running and imported < conf.maxBlocks and importedSlot <= endSlot:
        var clblock = getBlockFromEra(
          eraDB, historical_roots.asSeq(), historical_summaries.asSeq(), Slot(importedSlot), clConfig.cfg
        )
        if clblock.isSome:
          blocks.add getEth1Block(clblock.get())
          imported += 1

        importedSlot += 1
        if blocks.lenu64 mod conf.chunkSize == 0 and blocks.len > 0:
          process()

      if blocks.len > 0:
        process()

  for blocksFile in conf.blocksFile:
    if isFile(string blocksFile):
      # success or not, we quit after importing blocks
      if not importRlpBlock(string blocksFile, com):
        quit(QuitFailure)
      else:
        quit(QuitSuccess)
