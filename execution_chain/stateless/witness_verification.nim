# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/[tables, sets, algorithm],
  eth/common,
  ../db/ledger,
  ../db/aristo/aristo_proof,
  ./witness_types

template isAddress(bytes: openArray[byte]): bool =
  bytes.len() == 20

template isSlot(bytes: openArray[byte]): bool =
  bytes.len() == 32

template toAccountKey(address: Address): Hash32 =
  keccak256(address.data)

template toSlotKey(slot: UInt256): Hash32 =
  keccak256(slot.toBytesBE())

func putAll(
    keys: var Table[Address, HashSet[UInt256]],
    keysToAdd: openArray[seq[byte]]): Result[void, string] =

  var currentAddress: Address
  for key in keysToAdd:
    if key.isAddress():
      currentAddress = Address.copyFrom(key)
      keys.withValue(currentAddress, _):
        discard
      do:
        keys[currentAddress] = default(HashSet[UInt256])
    elif key.isSlot():
      keys.withValue(currentAddress, v):
        v[].incl(UInt256.fromBytesBE(key))
      do:
        var slots: HashSet[UInt256]
        slots.incl(UInt256.fromBytesBE(key))
        keys[currentAddress] = slots
    else:
      return err("malformed key length")

  ok()

func putAll(
    state: var Table[Hash32, seq[byte]],
    stateToAdd: openArray[seq[byte]]) =
  for node in stateToAdd:
    state[keccak256(node)] = node

# For testing
func validateKeys*(witness: Witness, expectedKeys: WitnessTable): Result[void, string] =
  if expectedKeys.len() != witness.keys.len():
    return err("expectedKeys.len() should match witness.keys.len()")
  if witness.keys.len() == 0:
    return err("witness.keys.len() == 0")
  if not witness.keys[0].isAddress():
    return err("first key should be an address")

  # Put all keys from the witness into a table to be searched later
  var keysTable: Table[Address, HashSet[UInt256]]
  ?keysTable.putAll(witness.keys)

  # For each of the expected witness keys check if the table contains
  # the key we are interested in and return err if any are missing.
  for key, _ in expectedKeys:
    let (address, slot) = key
    keysTable.withValue(address, v):
      if slot.isSome() and slot.get() notin v[]:
        return err("expected slot missing from witness keys")
    do:
      return err("expected address missing from witness keys")

  ok()

func verify*(witness: ExecutionWitness, preStateRoot: Hash32): Result[void, string] =

  var keysTable: Table[Address, HashSet[UInt256]]
  ?keysTable.putAll(witness.keys)

  var stateTable: Table[Hash32, seq[byte]]
  stateTable.putAll(witness.state)

  # Verify state against keys in witness
  var codeHashes: HashSet[Hash32]
  for address, slots in keysTable:
    let
      accPath = address.toAccountKey()
      maybeAccLeaf = verifyProof(stateTable, preStateRoot, accPath).valueOr:
        return err("Account proof verification failed against pre-stateroot")
      accLeaf = maybeAccLeaf.valueOr:
        continue

    let account =
      try:
        rlp.decode(accLeaf, Account)
      except RlpError as e:
        return err("Failed to decode account leaf from witness state: " & e.msg)
    codeHashes.incl(account.codeHash)

    # No point in verifying slot proofs against an empty root hash
    # because the verification will always return an error in this case.
    if account.storageRoot != EMPTY_ROOT_HASH:
      for slot in slots:
        let slotPath = slot.toSlotKey()
        discard verifyProof(stateTable, account.storageRoot, slotPath).valueOr:
          return err("Slot proof verification failed against pre-stateroot")

  # Verify codes in witness against codeHashes in the state
  for code in witness.codes:
    if keccak256(code) notin codeHashes:
      return err("Hash of code not found in witness state")

  # Verify witness headers
  if witness.headers.len() < 1:
    return err("At least one header (the parent) is required in the witness")
  if witness.headers.len() > 256:
    return err("Too many headers in witness")

  var headers: seq[Header]
  for header in witness.headers:
    try:
      headers.add(rlp.decode(header, Header))
    except RlpError as e:
      return err("Failed to decode header in witness: " & e.msg)

  func compareByNumber(a, b: Header): int =
    if a.number == b.number:
      0
    elif a.number > b.number:
      1
    else: # a.number < b.number
      -1
  headers.sort(compareByNumber)

  if headers[headers.high].stateRoot != preStateRoot:
    return err("Parent header should match the pre-stateroot")

  var i = headers.high
  while i > 0:
    if headers[i - 1].computeRlpHash() != headers[i].parentHash:
      return err("Header chain verification failed")
    dec i

  ok()
