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
  eth/rlp, stew/io2,
  ./chain,
  ../db/select_backend,
  ../common/common,
  ../utils/utils

proc importRlpBlock*(blocksRlp: openArray[byte]; com: CommonRef; importFile: string = ""): bool =
  var
    # the encoded rlp can contains one or more blocks
    rlp = rlpFromBytes(blocksRlp)
    chain = newChain(com, extraValidation = true)
    errorCount = 0
    header: BlockHeader
    body: BlockBody

  # The following kludge is needed for the `LegacyDbPersistent` type database
  # when `pruneTrie` is enabled. For other cases, this code is irrelevant.
  com.db.compensateLegacySetup()

  # even though the new imported blocks have block number
  # smaller than head, we keep importing it.
  # it maybe a side chain.

  while rlp.hasData:
    try:
      rlp.decompose(header, body)
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
