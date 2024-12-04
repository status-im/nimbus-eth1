# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  chronicles,
  eth/rlp,
  stew/io2,
  ./chain,
  ../config,
  ../utils/utils

proc importRlpBlocks*(blocksRlp: openArray[byte],
                      chain: ForkedChainRef,
                      finalize: bool):
                        Result[void, string] =
  var
    # the encoded rlp can contains one or more blocks
    rlp = rlpFromBytes(blocksRlp)
    blk: Block
    printBanner = false
    firstSkip = Opt.none(uint64)

  while rlp.hasData:
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
        hash=blk.header.blockHash.short,
        number=blk.header.number
      printBanner = true

    let res = chain.importBlock(blk)
    if res.isErr:
      error "Error occured when importing block",
        hash=blk.header.blockHash.short,
        number=blk.header.number,
        msg=res.error
      if finalize:
        ? chain.forkChoice(chain.latestHash, chain.latestHash)
      return res

  if finalize:
    ? chain.forkChoice(chain.latestHash, chain.latestHash)

  ok()

proc importRlpBlocks*(importFile: string,
                     chain: ForkedChainRef,
                     finalize: bool): Result[void, string] =
  let bytes = io2.readAllBytes(importFile).valueOr:
    return err($error)
  importRlpBlocks(bytes, chain, finalize)

proc importRlpBlocks*(conf: NimbusConf, com: CommonRef) =
  let head = com.db.getCanonicalHead().valueOr:
    error "cannot get canonical head from db", msg=error
    quit(QuitFailure)

  let chain = newForkedChain(com, head, baseDistance = 0)

  # success or not, we quit after importing blocks
  for i, blocksFile in conf.blocksFile:
    importRlpBlocks(string blocksFile, chain, i == conf.blocksFile.len-1).isOkOr:
      warn "Error when importing blocks", msg=error
      quit(QuitFailure)

  quit(QuitSuccess)
