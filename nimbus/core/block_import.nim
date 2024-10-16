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
  eth/rlp, stew/io2,
  ./chain,
  ../config

proc importRlpBlocks*(blocksRlp: openArray[byte],
                      chain: ForkedChainRef,
                      finalize: bool):
                        Result[void, string] =
  var
    # the encoded rlp can contains one or more blocks
    rlp = rlpFromBytes(blocksRlp)
    blk: Block

  # even though the new imported blocks have block number
  # smaller than head, we keep importing it.
  # it maybe a side chain.
  while rlp.hasData:
    blk = try:
      rlp.read(Block)
    except RlpError as e:
      # terminate if there was a decoding error
      return err($e.name & ": " & e.msg)

    ? chain.importBlock(blk)

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
  var head: Header
  if not com.db.getCanonicalHead(head):
    error "cannot get canonical head from db"
    quit(QuitFailure)

  let chain = newForkedChain(com, head, baseDistance = 0)

  # success or not, we quit after importing blocks
  for i, blocksFile in conf.blocksFile:
    importRlpBlocks(string blocksFile, chain, i == conf.blocksFile.len-1).isOkOr:
      warn "Error when importing blocks", msg=error
      quit(QuitFailure)

  quit(QuitSuccess)
