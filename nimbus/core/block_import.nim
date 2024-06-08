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
  ../common/common,
  ../utils/utils

proc importRlpBlock*(blocksRlp: openArray[byte]; com: CommonRef; importFile: string = ""): bool =
  var
    # the encoded rlp can contains one or more blocks
    rlp = rlpFromBytes(blocksRlp)
    chain = newChain(com, extraValidation = true)
    errorCount = 0
    blk: array[1, EthBlock]

  # even though the new imported blocks have block number
  # smaller than head, we keep importing it.
  # it maybe a side chain.
  # TODO the above is no longer true with a single-state database - to deal with
  #      that scenario the code needs to be rewritten to not persist the blocks
  #      to the state database until all have been processed
  while rlp.hasData:
    blk[0] = try:
      rlp.read(EthBlock)
    except RlpError as e:
      # terminate if there was a decoding error
      error "rlp error",
        fileName = importFile,
        msg = e.msg,
        exception = e.name
      return false

    chain.persistBlocks(blk).isOkOr():
      # register one more error and continue
      error "import error",
        fileName = importFile,
        error
      errorCount.inc

  return errorCount == 0

proc importRlpBlock*(importFile: string; com: CommonRef): bool =
  let res = io2.readAllBytes(importFile)
  if res.isErr:
    error "failed to import",
      fileName = importFile
    return false

  importRlpBlock(res.get, com, importFile)
