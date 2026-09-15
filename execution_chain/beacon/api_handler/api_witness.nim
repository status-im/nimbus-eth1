# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# Support for the engine_newPayloadWithWitness* methods. These are not (yet)
# part of the Engine API spec.

{.push gcsafe, raises: [].}

import results, chronicles, eth/common, eth/rlp, ../beacon_engine

from ../../stateless/witness_generation import ExecutionWitnessWithKeys
from ../../utils/utils import short

logScope:
  topics = "beacon engine"

type
  # Current execution witness wire shape, returned by the engine_newPayloadWithWitness*
  # methods as an RLP blob. The field order (headers, codes, state, keys)
  # is significant and must match go-ethereum / ethrex:
  # https://github.com/ethereum/go-ethereum/blob/master/core/stateless/encoding.go
  # This is currently not specced out in the Engine API.
  # Note that it is different from debug_executionWitness encoding.
  ExtWitness = object
    headers: seq[Header]
    codes: seq[seq[byte]]
    state: seq[seq[byte]]
    keys: seq[seq[byte]]

func encodeExtWitness(w: ExecutionWitnessWithKeys): Result[seq[byte], string] =
  ## RLP-encode the witness into geth's execution witness wire format.
  var headers: seq[Header]
  for encodedHeader in w.headers:
    let header =
      try:
        rlp.decode(encodedHeader, Header)
      except RlpError as e:
        return err("Failed to decode witness header: " & e.msg)
    headers.add(header)

  ok(
    rlp.encode(ExtWitness(headers: headers, codes: w.codes, state: w.state, keys: @[]))
  )

proc collectWitness*(ben: BeaconEngineRef, blk: Block): Opt[seq[byte]] =
  ## Return the RLP-encoded execution witness for `blk`, or none if unavailable.
  ## When the node runs with `--stateless-provider` the witness stored during
  ## import is used else it is generated on demand by re-executing the block
  ## against its parent state.
  let blockHash = blk.header.computeBlockHash()

  let witness =
    if ben.chain.com.statelessProvider:
      ben.chain.getExecutionWitness(blockHash)
    else:
      ben.chain.generateExecutionWitness(blk)

  let w = witness.valueOr:
    warn "Execution witness not available", hash = blockHash.short, error = error
    return Opt.none(seq[byte])

  let encoded = encodeExtWitness(w).valueOr:
    warn "Failed to encode execution witness", hash = blockHash.short, error = error
    return Opt.none(seq[byte])

  Opt.some(encoded)
