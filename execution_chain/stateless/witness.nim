# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  eth/common,
  eth/rlp,
  results

export
  results

{.push raises: [].}

type
  ExecutionWitness* = object
    state*: seq[seq[byte]] # MPT trie nodes accessed while executing the block.
    codes*: seq[seq[byte]] # Contract bytecodes read while executing the block.
    keys*: seq[seq[byte]] # Ordered list of access keys (address bytes or storage slots bytes).
    headers*: seq[Header] # Block headers required for proving correctness of stateless execution.
      # Stores the parent block headers needed to verify that the state reads are correct with respect
      # to the pre-state root.

func encode(witness: ExecutionWitness): seq[byte] =
  rlp.encode(witness)

func decode(witnessBytes: openArray[byte]): Result[ExecutionWitness, string] =
  try:
    ok(rlp.decode(witnessBytes, ExecutionWitness))
  except RlpError as e:
    err(e.msg)
