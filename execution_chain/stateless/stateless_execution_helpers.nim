# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import eth/common/blocks_rlp, ./stateless_execution

export stateless_execution

proc statelessProcessBlock*(
    witnessBytes: openArray[byte], com: CommonRef, blkBytes: openArray[byte]
): Result[void, string] =
  let
    witness = ?ExecutionWitness.decode(witnessBytes)
    blk =
      try:
        rlp.decode(blkBytes, Block)
      except RlpError as e:
        return err(e.msg)
  statelessProcessBlock(witness, com, blk)

proc statelessProcessBlock*(
    witnessBytes: openArray[byte],
    id: NetworkId,
    config: ChainConfig,
    blkBytes: openArray[byte],
): Result[void, string] =
  let
    witness = ?ExecutionWitness.decode(witnessBytes)
    blk =
      try:
        rlp.decode(blkBytes, Block)
      except RlpError as e:
        return err(e.msg)
  statelessProcessBlock(witness, id, config, blk)

proc statelessProcessBlock*(
    witnessBytes: openArray[byte], id: NetworkId, blkBytes: openArray[byte]
): Result[void, string] =
  let
    witness = ?ExecutionWitness.decode(witnessBytes)
    blk =
      try:
        rlp.decode(blkBytes, Block)
      except RlpError as e:
        return err(e.msg)
  statelessProcessBlock(witness, id, chainConfigForNetwork(id), blk)

## create function that takes json types
