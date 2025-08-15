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
  std/[tables, sets],
  eth/common,
  ../db/ledger,
  ./witness_types

func isAddress(bytes: openArray[byte]): bool =
  bytes.len() == 20

func isSlot(bytes: openArray[byte]): bool =
  bytes.len() == 32

func validateKeys*(witness: Witness, expectedKeys: WitnessTable): Result[void, string] =
  if expectedKeys.len() != witness.keys.len():
    return err("witnessKeys.len() should match witness.keys.len()")
  if witness.keys.len() == 0:
    return err("witness.keys.len() == 0")
  if not witness.keys[0].isAddress():
    return err("first key should be an address")

  var
    discovered: Table[Address, HashSet[UInt256]]
    currentAddress: Address

  # Put all keys from the witness into a table to be searched later
  for key in witness.keys:
    if key.isAddress():
      currentAddress = Address.copyFrom(key)
      discovered.withValue(currentAddress, v):
        discard
      do:
        discovered[currentAddress] = default(HashSet[UInt256])
    elif key.isSlot():
      discovered.withValue(currentAddress, v):
        v[].incl(UInt256.fromBytesBE(key))
      do:
        var slots: HashSet[UInt256]
        slots.incl(UInt256.fromBytesBE(key))
        discovered[currentAddress] = slots
    else:
      return err("malformed key length")

  # For each of the expected witness keys check if the table contains
  # the key we are interested in and return err if any are missing.
  for key, _ in expectedKeys:
    let (address, slot) = key

    discovered.withValue(address, v):
      if slot.isSome() and slot.get() notin v[]:
        return err("expected slot missing from witness keys")
    do:
      return err("expected address missing from witness keys")

  ok()
