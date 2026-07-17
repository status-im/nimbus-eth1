# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/[tables, sets],
  eth/common,
  ../db/ledger,
  ../db/aristo/aristo_proof,
  ./[witness_types, stateless_types]

template isAddress(bytes: openArray[byte]): bool =
  bytes.len() == 20

template isSlot(bytes: openArray[byte]): bool =
  bytes.len() == 32

func putAll(
    keys: var Table[Address, HashSet[UInt256]], keysToAdd: openArray[seq[byte]]
): Result[void, string] =
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

func putAll(state: var Table[Hash32, seq[byte]], stateToAdd: openArray[seq[byte]]) =
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

# https://github.com/ethereum/execution-specs/blob/bd8c673552d957dbe9c9f3f2656b87201f5ae646/src/ethereum/forks/amsterdam/stateless.py#L281
func verifyHeaders*(
    witness: ExecutionWitness, header: Header
): Result[seq[Header], string] =
  if witness.headers.len() < 1:
    return err("At least one header (the parent) is required in the witness")
  if witness.headers.len() > 256:
    return err("Too many headers in witness")

  # Rlp decode the headers in the witness
  var headers: seq[Header]
  for h in witness.headers:
    try:
      headers.add(rlp.decode(h.asSeq(), Header))
    except RlpError as e:
      return err("Failed to decode header in witness: " & e.msg)

  # Validate that a sequence of encoded headers forms a contiguous chain
  for i in 1..<headers.len:
    if headers[i].parentHash != keccak256(witness.headers[i - 1].asSeq()):
      return err("Witness headers are not contiguous")

  # The last provided header must be the parent of the block being validated.
  # This anchors preStateRoot (taken from the last witness header) to the block's
  # parentHash: without it an attacker could supply a fabricated last header with
  # an arbitrary stateRoot, paired with matching fake trie nodes, and pass the
  # preStateRoot check in statelessProcessBlock() while executing on a bogus
  # pre-state.
  #
  # Note that execution-specs does the same check inside execute_block via
  # validate_header().
  if keccak256(witness.headers[^1].asSeq()) != header.parentHash:
    return err("Parent header is required in the witness")

  ok(headers)

func verifyState*(
    witness: ExecutionWitnessWithKeys, preStateRoot: Hash32
): Result[void, string] =
  # Short path for emptyRoot -> empty trie: no accounts exist in the pre-state,
  # nothing to verify.
  # Without this check verifyProof will return an error.
  if preStateRoot == emptyRoot:
    return ok()

  # Verify state against keys in witness
  var keysTable: Table[Address, HashSet[UInt256]]
  ?keysTable.putAll(witness.keys)

  var stateTable: Table[Hash32, seq[byte]]
  stateTable.putAll(witness.state)

  var codeHashes: HashSet[Hash32]
  for address, slots in keysTable:
    let
      accPath = address.computeAccPath()
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
        let slotPath = slot.computeSlotKey()
        discard verifyProof(stateTable, account.storageRoot, slotPath).valueOr:
          return err("Slot proof verification failed against pre-stateroot")

  # Verify codes in witness against codeHashes in the state
  for code in witness.codes:
    if keccak256(code) notin codeHashes:
      return err("Hash of code not found in witness state")

  ok()
