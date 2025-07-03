# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[tables, sets],
  eth/common,
  eth/rlp,
  results,
  ../db/ledger

export
  common,
  results,
  ledger

{.push raises: [].}

type
  WitnessKey* = object
    storageMode*: bool
    address*: Address
    codeTouched*: bool
    storageSlot*: UInt256

  WitnessTable* = OrderedTable[(Address, Hash32), WitnessKey]

  ExecutionWitness* = object
    state*: seq[seq[byte]] # MPT trie nodes accessed while executing the block.
    codes*: seq[seq[byte]] # Contract bytecodes read while executing the block.
    keys*: seq[seq[byte]] # Ordered list of access keys (address bytes or storage slots bytes).
    headers*: seq[Header] # Block headers required for proving correctness of stateless execution.
      # Stores the parent block headers needed to verify that the state reads are correct with respect
      # to the pre-state root.

func init*(
    T: type ExecutionWitness,
    state = newSeq[seq[byte]](),
    codes = newSeq[seq[byte]](),
    keys = newSeq[seq[byte]](),
    headers = newSeq[Header]()): T =
  ExecutionWitness(state: state, codes: codes, keys: keys, headers: headers)

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

func build*(
    T: type ExecutionWitness,
    ledger: LedgerRef,
    witnessKeys: WitnessTable,
    headers: openArray[Header]): T =
  var
    witness = ExecutionWitness.init()
    addedStateHashes = initHashSet[Hash32]()
    addedCodeHashes = initHashSet[Hash32]()

  for key in witnessKeys.values():
    if key.storageMode:
      witness.addKey(key.storageSlot.toBytesBE())

      let proofs = ledger.getStorageProof(key.address, @[key.storageSlot])
      doAssert(proofs.len() == 1)
      for trieNode in proofs[0]:
        let nodeHash = keccak256(trieNode)
        if nodeHash notin addedStateHashes:
          witness.addState(trieNode)
          addedStateHashes.incl(nodeHash)
    else:
      witness.addKey(key.address.toBytes())

      let proof = ledger.getAccountProof(key.address)
      for trieNode in proof:
        let nodeHash = keccak256(trieNode)
        if nodeHash notin addedStateHashes:
          witness.addState(trieNode)
          addedStateHashes.incl(nodeHash)

    if key.codeTouched:
      let (codeHash, code) = ledger.getCode(key.address, returnHash = true)
      if codeHash != EMPTY_CODE_HASH and codeHash notin addedCodeHashes:
        witness.addCode(code.bytes)
        addedCodeHashes.incl(codeHash)

  for h in headers:
    witness.addHeader(h)

  witness
