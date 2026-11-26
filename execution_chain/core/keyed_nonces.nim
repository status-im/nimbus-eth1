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
  LEGACY_NONCE_KEYS* = default(seq[UInt256])
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
  if tx.nonceKeys.len > MAX_NONCE_KEYS:
    return err("invalid nonce key count")

  for i in 1..<tx.nonceKeys.len:
    if tx.nonceKeys[i] <= tx.nonceKeys[i - 1]:
      return err("nonce keys not strictly increasing")

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
  if tx.nonceKeys.len == 0 or tx.nonceSeq != MAX_NONCE_SEQ:
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
  ## Every key reads the nonce manager, where an absent slot is sequence
  ## zero: the protocol never writes zero, so a zero read identifies a
  ## key's first use.
  let slot = nonceSlot(sender, nonceKey)
  if vmState.balTrackerEnabled:
    vmState.balTracker.trackStorageRead(NONCE_MANAGER, slot)
  let nonce = vmState.readOnlyLedger.getStorage(NONCE_MANAGER, slot)
  nonce.truncate(uint64)

func checkSequence(current: uint64, nonceSeq: uint64): Result[void, string] =
  ## Check that a nonce domain's current sequence equals the
  ## transaction's sequence.

  if current > nonceSeq:
    return err("nonce too low")
  elif current < nonceSeq:
    return err("nonce too high")

  ok()

proc checkNonceSet*(vmState: BaseVMState, tx: Transaction): Result[void, string] =
  ## Check the transaction's nonce domain against its sequence.

  ## The empty key set requires the sender's account nonce to equal the
  ## sequence. A keyed set at [`MAX_NONCE_SEQ`][mns] requires every
  ## selected key to be unused; any other keyed set requires every
  ## selected key to hold the sequence.

  if tx.nonceKeys == LEGACY_NONCE_KEYS:
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackAddressAccess(tx.sender)
    let nonce = vmState.readOnlyLedger.getNonce(tx.sender)
    return checkSequence(nonce, tx.nonceSeq)

  for nonceKey in tx.nonceKeys:
    let
      current = currentNonceSeq(vmState, tx.sender, nonceKey)

    if tx.nonceSeq == MAX_NONCE_SEQ:
      if current != 0:
        return err("nonce too low")
    else:
      ? checkSequence(current, tx.nonceSeq)

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
  ## A keyed set advances each selected sequence past the transaction's
  ## sequence, except at [`MAX_NONCE_SEQ`][mns], where it exhausts each
  ## selected key by writing that sequence.

  if tx.nonceKeys == LEGACY_NONCE_KEYS:
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackIncNonceChange(tx.sender)
    vmState.ledger.incNonce(tx.sender)
    return

  let consumedSeq = if tx.nonceSeq == MAX_NONCE_SEQ: MAX_NONCE_SEQ.u256
                    else: tx.nonceSeq.u256 + 1.u256

  for nonceKey in tx.nonceKeys:
    let
      slot = nonceSlot(tx.sender, nonceKey)
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackStorageWrite(NONCE_MANAGER, slot, consumedSeq)
    vmState.ledger.setStorage(NONCE_MANAGER, slot, consumedSeq)
