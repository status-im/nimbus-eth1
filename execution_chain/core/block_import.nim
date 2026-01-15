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
  eth/common,
  stew/io2,
  chronos,
  ./chain,
  ../conf,
  ../utils/utils,
  beacon_chain/process_state,
  ./chain/forked_chain/chain_serialize

# Only parse the RLP data and feeds blocks into the ForkedChainRef
# Dont make any fork-choice calls here
proc importRlpBlocks*(blocksRlp: seq[byte],
                      chain: ForkedChainRef):
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
      return res

  ok()

proc importRlpBlocks*(importFile: string,
                     chain: ForkedChainRef): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  let bytes = io2.readAllBytes(importFile).valueOr:
    return err($error)
  await importRlpBlocks(bytes, chain)

# Handle the  fork-choice update
proc finalizeImportedChain(
    chain: ForkedChainRef,
    treatSegmentFinalized: bool
  ): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  let headHash = chain.latestHash
  var finalizedHash =
    if treatSegmentFinalized:
      headHash
    else:
      chain.resolvedFinHash()
  # for when chain is brand new, fall back to the current base hash
  if finalizedHash == Hash32.default:
    finalizedHash = chain.baseHash()

  (await chain.forkChoice(headHash, finalizedHash)).isOkOr:
    return err(error)
  ok()

proc importRlpFiles*(
    files: seq[string],
    com: CommonRef,
    treatSegmentFinalized: bool
  ): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  if files.len == 0:
    return ok()

  let chain = ForkedChainRef.init(com, baseDistance = 0, persistBatchSize = 1)

  for blocksFile in files:
    (await importRlpBlocks(blocksFile, chain)).isOkOr:
      let errMsg = error
      (await finalizeImportedChain(chain, true)).isOkOr:
        error "Error when finalizing chain after import failure", msg=error
      return err(errMsg)

  (await finalizeImportedChain(chain, treatSegmentFinalized)).isOkOr:
    return err(error)

  let txFrame = chain.baseTxFrame
  chain.serialize(txFrame).isOkOr:
    return err("FC.serialize error: " & ($error))
  txFrame.checkpoint(chain.base.blk.header.number, skipSnapshot = true)
  com.db.persist(txFrame)

  ok()
