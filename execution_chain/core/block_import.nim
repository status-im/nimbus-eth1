# Nimbus
# Copyright (c) 2021-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  chronicles,
  eth/rlp,
  stew/io2,
  chronos,
  ./chain,
  ../conf,
  ../utils/utils,
  beacon_chain/process_state,
  ./chain/forked_chain/chain_serialize

proc importRlpBlocks*(blocksRlp:seq[byte],
                      chain: ForkedChainRef,
                      finalize: bool):
                        Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  var
    # the encoded rlp can contains one or more blocks
    rlp = rlpFromBytes(blocksRlp)
    blk: Block
    printBanner = false
    firstSkip = Opt.none(uint64)

  while not ProcessState.stopIt(notice("Shutting down", reason = it)) and rlp.hasData:
    blk = try:
      rlp.read(Block)
    except RlpError as e:
      # terminate if there was a decoding error
      return err($e.name & ": " & e.msg)

    if blk.header.number <= chain.baseNumber:
      if firstSkip.isNone:
        firstSkip = Opt.some(blk.header.number)
      continue

    if firstSkip.isSome:
      if firstSkip.get == blk.header.number - 1:
        info "Block number smaller than base",
          skip=firstSkip.get
      else:
        info "Block number smaller than base",
          startSkip=firstSkip.get,
          skipTo=blk.header.number-1
      firstSkip.reset()

    if not printBanner:
      info "Start importing block",
        hash=blk.header.computeBlockHash.short,
        number=blk.header.number
      printBanner = true

    let res = await chain.importBlock(blk)
    if res.isErr:
      error "Error occured when importing block",
        hash=blk.header.computeBlockHash.short,
        number=blk.header.number,
        msg=res.error
      if finalize:
        ? (await chain.forkChoice(chain.latestHash, chain.latestHash))
      return res

  if finalize:
    ? (await chain.forkChoice(chain.latestHash, chain.latestHash))

  ok()

proc importRlpBlocks*(importFile: string,
                     chain: ForkedChainRef,
                     finalize: bool): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  let bytes = io2.readAllBytes(importFile).valueOr:
    return err($error)
  await importRlpBlocks(bytes, chain, finalize)

proc importRlpBlocks*(config: ExecutionClientConf, com: CommonRef): Future[void] {.async: (raises: [CancelledError]).} =
  # Both baseDistance and persistBatchSize are 0,
  # we want changes persisted immediately
  let chain = ForkedChainRef.init(com, baseDistance = 0, persistBatchSize = 1)

  # success or not, we quit after importing blocks
  for i, blocksFile in config.blocksFile:
    (await importRlpBlocks(string blocksFile, chain, false)).isOkOr:
      warn "Error when importing blocks", msg=error
      # Finalize the existing chain in case of rlp read error
      (await chain.forkChoice(chain.latestHash, chain.latestHash)).isOkOr:
        error "Error when finalizing chain", msg=error
      quit(QuitFailure)

  let txFrame = chain.baseTxFrame
  chain.serialize(txFrame).isOkOr:
    error "FC.serialize error: ", msg = error
  txFrame.checkpoint(chain.base.blk.header.number, skipSnapshot = true)
  com.db.persist(txFrame)

  quit(QuitSuccess)
