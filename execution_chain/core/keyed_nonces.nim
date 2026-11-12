# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

{.push raises: [].}

import
  eth/common/hashes,
  eth/common/addresses,
  eth/common/base_rlp,
  eth/common/transactions_rlp,
  results,
  ../evm/[state, types]

from ./eip8037 import
  STATE_BYTES_PER_STORAGE_SET,
  COST_PER_STATE_BYTE

from ../evm/interpreter/gas_costs import
  COLD_STORAGE_ACCESS_8038,
  STORAGE_WRITE_8038

const
  MAX_NONCE_KEYS* = 16
  MAX_NONCE_SEQ* = uint64.high
  KEYED_NONCE_FIRST_USE* = STATE_BYTES_PER_STORAGE_SET * COST_PER_STATE_BYTE
  LEGACY_NONCE_KEYS* = @[0.u256]
  NONCE_MANAGER = address"8250968c12e01a19d6f667b9b2f3b3a4d0e51cb7"
  KEYED_NONCE_ACCESS* = COLD_STORAGE_ACCESS_8038 + STORAGE_WRITE_8038

template nonceSeq*(tx: ptr Transaction): uint64 =
  tx.nonce

func validateNonceKeys*(tx: Transaction): Result[void, string] =
  ## Check that a transaction selects a well-formed set of nonce keys.
  ##
  ## The set holds between one and [`MAX_NONCE_KEYS`][mnk] keys in
  ## strictly increasing order, so each set has one canonical encoding.
  ## The zero key aliases the sender's account nonce and may only appear
  ## alone, as [`LEGACY_NONCE_KEYS`][lnk].

  let
    keyCount = tx.nonceKeys.len

  if keyCount < 1 or keyCount > MAX_NONCE_KEYS:
    return err("invalid nonce key count")

  for i in 1..<tx.nonceKeys.len:
    if tx.nonceKeys[i] <= tx.nonceKeys[i - 1]:
      return err("nonce keys not strictly increasing")

  if 0.u256 in tx.nonceKeys and tx.nonceKeys != LEGACY_NONCE_KEYS:
    return err("zero nonce key alongside other keys")

  ok()

func nonceKeysHash*(tx: Transaction): Hash32 =
  ## Return the commitment to the transaction's nonce key set exposed to
  ## the EVM: the hash of the key count followed by every key, each as a
  ## 32-byte big-endian word.

  withKeccak256:
    h.update(tx.nonceKeys.len.u256.toBytesBE)
    for nonceKey in tx.nonceKeys:
      h.update(nonceKey.toBytesBE)

func nonceCallData*(tx: Transaction): seq[byte] =
  ## Return the encoding of the transaction's nonce fields, which is
  ## priced as transaction data.

  result = rlp.encode(tx.nonceKeys)
  result.add rlp.encode(tx.nonceSeq)

func nonceSlot(sender: Address, nonceKey: UInt256): UInt256 =
  ## Return the nonce manager storage slot holding `sender`'s sequence
  ## for `nonce_key`: the hash of the left-padded sender address followed
  ## by the big-endian key.
  let
    pad = default(array[12, byte])
    slot = withKeccak256:
             h.update(pad)
             h.update(sender.data)
             h.update(nonceKey.toBytesBE)
  result.initFromBytesBE(slot.data)

proc currentNonceSeq(vmState: BaseVMState, sender: Address, nonceKey: UInt256): uint64 =
  ## Return the current sequence of `sender`'s nonce domain `nonce_key`.
  ##
  ## The zero key reads the account nonce. Any other key reads the nonce
  ## manager, where an absent slot is sequence zero: the protocol never
  ## writes zero, so a zero read identifies a key's first use.

  if nonceKey.isZero:
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackAddressAccess(sender)
    return vmState.readOnlyLedger.getNonce(sender)

  let slot = nonceSlot(sender, nonceKey)
  if vmState.balTrackerEnabled:
    vmState.balTracker.trackStorageRead(NONCE_MANAGER, slot)
  let nonce = vmState.readOnlyLedger.getStorage(NONCE_MANAGER, slot)
  nonce.truncate(uint64)

proc checkNonceSet*(vmState: BaseVMState, tx: Transaction): Result[void, string] =
  ## Check that every nonce key the transaction selects currently holds
  ## the transaction's sequence.

  for nonceKey in tx.nonceKeys:
    let
      current = currentNonceSeq(vmState, tx.sender, nonceKey)

    if current > tx.nonceSeq:
      return err("nonce too low")
    elif current < tx.nonceSeq:
      return err("nonce too high")
  ok()

proc countFirstUses*(vmState: BaseVMState, tx: Transaction): uint64 =
  ## Return how many of the transaction's keyed nonce slots are still
  ## unused, each of which consuming the nonce set creates.

  var
    count = 0'u64
  for nonceKey in tx.nonceKeys:
    if currentNonceSeq(vmState, tx.sender, nonceKey) == 0:
      count += 1
  count

proc consumeNonceSet*(vmState: BaseVMState, tx: Transaction) =
  ## Consume the transaction's nonce set, once, on payment approval.
  ##
  ## The legacy key set increments the sender's account nonce, whatever
  ## it currently is, rather than setting it to the transaction's
  ## sequence plus one: an earlier frame may already have changed it.
  ## Any other key set advances each selected keyed sequence past the
  ## transaction's sequence.

  if tx.nonceKeys == LEGACY_NONCE_KEYS:
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackIncNonceChange(tx.sender)
    vmState.ledger.incNonce(tx.sender)
    return
  for nonceKey in tx.nonceKeys:
    let
      slot = nonceSlot(tx.sender, nonceKey)
      newValue = (tx.nonceSeq + 1).u256
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackStorageWrite(NONCE_MANAGER, slot, newValue)
    vmState.ledger.setStorage(NONCE_MANAGER, slot, newValue)
