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
  common,
  results

{.push raises: [].}

type
  Witness* = object
    state*: seq[seq[byte]] # MPT trie nodes accessed while executing the block.
    keys*: seq[seq[byte]] # Ordered list of access keys (address bytes or storage slots bytes).
    codeHashes*: seq[Hash32] # Code hashes of the bytecode required by the witness.
    headerHashes*: seq[Hash32] # Hashes of block headers which are required by the witness.

  ExecutionWitness* = object
    state*: seq[seq[byte]] # MPT trie nodes accessed while executing the block.
    keys*: seq[seq[byte]] # Ordered list of access keys (address bytes or storage slots bytes).
    codes*: seq[seq[byte]] # Contract bytecodes read while executing the block.
    headers*: seq[Header] # Block headers required for proving correctness of stateless execution.
      # Stores the parent block headers needed to verify that the state reads are correct with respect
      # to the pre-state root.

func init*(
    T: type Witness,
    state = newSeq[seq[byte]](),
    keys = newSeq[seq[byte]](),
    codeHashes = newSeq[Hash32](),
    headerHashes = newSeq[Hash32]()): T =
  Witness(state: state, keys: keys, headerHashes: headerHashes)

template addState*(witness: var Witness, trieNode: seq[byte]) =
  witness.state.add(trieNode)

template addKey*(witness: var Witness, key: seq[byte]) =
  witness.keys.add(key)

template addCodeHash*(witness: var Witness, codeHash: Hash32) =
  witness.codeHashes.add(codeHash)

template addHeaderHash*(witness: var Witness, headerHash: Hash32) =
  witness.headerHashes.add(headerHash)

func encode*(witness: Witness): seq[byte] =
  rlp.encode(witness)

func decode*(T: type Witness, witnessBytes: openArray[byte]): Result[T, string] =
  try:
    ok(rlp.decode(witnessBytes, T))
  except RlpError as e:
    err(e.msg)

func init*(
    T: type ExecutionWitness,
    state = newSeq[seq[byte]](),
    keys = newSeq[seq[byte]](),
    codes = newSeq[seq[byte]](),
    headers = newSeq[Header]()): T =
  ExecutionWitness(state: state, keys: keys, codes: codes, headers: headers)

template addState*(witness: var ExecutionWitness, trieNode: seq[byte]) =
  witness.state.add(trieNode)

template addCode*(witness: var ExecutionWitness, code: seq[byte]) =
  witness.codes.add(code)

template addKey*(witness: var ExecutionWitness, key: seq[byte]) =
  witness.keys.add(key)

template addHeader*(witness: var ExecutionWitness, header: Header) =
  witness.headers.add(header)

func encode*(witness: ExecutionWitness): seq[byte] =
  rlp.encode(witness)

func decode*(T: type ExecutionWitness, witnessBytes: openArray[byte]): Result[T, string] =
  try:
    ok(rlp.decode(witnessBytes, T))
  except RlpError as e:
    err(e.msg)
