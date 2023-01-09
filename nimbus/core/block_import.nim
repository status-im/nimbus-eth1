# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  chronicles,
  eth/common/eth_types_rlp,  # we need the BlockBody specialization of readRecordType
  eth/rlp,
  stew/io2,
  ./chain,
  ../db/select_backend,
  ../common/common

type
  # trick the rlp decoder
  # so we can separate the body and header
  EthHeader = object
    header: BlockHeader

proc importRlpBlock*(blocksRlp: openArray[byte]; com: CommonRef; importFile: string = ""): bool =
  var
    # the encoded rlp can contains one or more blocks
    rlp = rlpFromBytes(blocksRlp)
    chain = newChain(com, extraValidation = true)
    errorCount = 0
  let
    head = com.db.getCanonicalHead()

  while rlp.hasData:
    try:
      let
        header = rlp.read(EthHeader).header
        body = rlp.readRecordType(BlockBody, false)
      if header.blockNumber > head.blockNumber:
        if chain.persistBlocks([header], [body]) == ValidationResult.Error:
          # register one more error and continue
          errorCount.inc
    except RlpError as e:
      # terminate if there was a decoding error
      error "rlp error",
        fileName = importFile,
        msg = e.msg,
        exception = e.name
      return false
    except CatchableError as e:
      # otherwise continue
      error "import error",
        fileName = importFile,
        msg = e.msg,
        exception = e.name
      errorCount.inc

  return errorCount == 0

proc importRlpBlock*(importFile: string; com: CommonRef): bool =
  let res = io2.readAllBytes(importFile)
  if res.isErr:
    error "failed to import",
      fileName = importFile
    return false

  importRlpBlock(res.get, com, importFile)
