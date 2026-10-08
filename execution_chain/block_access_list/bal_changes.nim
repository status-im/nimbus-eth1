# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  eth/common/[addresses, base, hashes],
  stint,
  ../evm/code_bytes

export addresses, base, hashes, stint, code_bytes

type
  BalanceDiff* = tuple[address: Address, pre, post: UInt256]
  NonceDiff* = tuple[address: Address, pre, post: AccountNonce]
  StorageDiff* = tuple[address: Address, slot, pre, post: UInt256]
  CodeDiff* = tuple[address: Address, pre, post: Hash32]

  BalChanges* = object
    balances*: seq[BalanceDiff]
    nonces*: seq[NonceDiff]
    slots*: seq[StorageDiff]
    codeDiffs*: seq[CodeDiff]
    codes*: seq[CodeBytesRef]
    merging*: bool

  BalChangesRef* = ref BalChanges

func clear*(c: var BalChanges) =
  c.balances.setLen(0)
  c.nonces.setLen(0)
  c.slots.setLen(0)
  c.codeDiffs.setLen(0)
  c.codes.setLen(0)
  c.merging = false

func isEmpty*(c: BalChanges): bool =
  c.balances.len == 0 and c.nonces.len == 0 and c.slots.len == 0 and
    c.codeDiffs.len == 0

func recordBalance*(c: var BalChanges, address: Address, pre, post: UInt256) =
  if c.merging:
    for e in c.balances.mitems():
      if e.address == address:
        e.post = post
        return
  c.balances.add((address, pre, post))

func recordNonce*(c: var BalChanges, address: Address, pre, post: AccountNonce) =
  if c.merging:
    for e in c.nonces.mitems():
      if e.address == address:
        e.post = post
        return
  c.nonces.add((address, pre, post))

func recordCode*(
    c: var BalChanges, address: Address, pre, post: Hash32, code: CodeBytesRef
) =
  if c.merging:
    for i in 0 ..< c.codeDiffs.len:
      if c.codeDiffs[i].address == address:
        c.codeDiffs[i].post = post
        c.codes[i] = code
        return
  c.codeDiffs.add((address, pre, post))
  c.codes.add(code)

func recordSlot*(c: var BalChanges, address: Address, slot, pre, post: UInt256) =
  if c.merging:
    for e in c.slots.mitems():
      if e.address == address and e.slot == slot:
        e.post = post
        return
  c.slots.add((address, slot, pre, post))
