# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[terminal, os],
  chronicles, eth/trie/db, eth/[common, rlp], stew/[io2, byteutils],
  ./config, ./genesis, ./p2p/chain,
  ./db/[db_chain, select_backend, storage_types]

type
  # trick the rlp decoder
  # so we can separate the body and header
  EthHeader = object
    header: BlockHeader

proc importRlpBlock*(importFile: string, chainDB: BasechainDB): bool =
  let res = io2.readAllBytes(importFile)
  if res.isErr:
    error "failed to import", fileName = importFile
    return false

  var chain = newChain(chainDB, extraValidation = true)
  # the encoded rlp can contains one or more blocks
  var rlp = rlpFromBytes(res.get)
  let head = chainDB.getCanonicalHead()

  try:
    while true:
      let header = rlp.read(EthHeader).header
      let body = rlp.readRecordType(BlockBody, false)
      if header.blockNumber > head.blockNumber:
        let valid = chain.persistBlocks([header], [body])
        if valid == ValidationResult.Error:
          error "failed to import rlp encoded blocks", fileName = importFile
          return false
      if not rlp.hasData:
        break
  except CatchableError as e:
    error "rlp error", fileName = importFile, msg = e.msg, exception = e.name
    return false

  return true
