# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  chronicles,
  eth/[rlp, trie/db],
  ../../db/[storage_types, db_chain]

type
  # transitionStatus describes the status of eth1/2 transition. This switch
  # between modes is a one-way action which is triggered by corresponding
  # consensus-layer message.
  TransitionStatus = object
    leftPoW   : bool # The flag is set when the first NewHead message received
    enteredPoS: bool # The flag is set when the first FinalisedBlock message received

  # Merger is an internal help structure used to track the eth1/2 transition status.
  # It's a common structure can be used in both full node and light client.
  MergerRef* = ref object
    db    : TrieDatabaseRef
    status: TransitionStatus

proc writeStatus(db: TrieDatabaseRef, status: TransitionStatus) =
  db.put(transitionStatusKey().toOpenArray(), rlp.encode(status))

proc readStatus(db: TrieDatabaseRef): TransitionStatus =
  var bytes = db.get(transitionStatusKey().toOpenArray())
  if bytes.len > 0:
    try:
      result = rlp.decode(bytes, typeof result)
    except CatchableError:
      error "Failed to decode POS transition status"

proc new*(_: type MergerRef, db: TrieDatabaseRef): MergerRef =
  MergerRef(
    db: db,
    status: db.readStatus()
  )

proc new*(_: type MergerRef, db: ChainDBRef): MergerRef =
  MergerRef.new(db.db)

# ReachTTD is called whenever the first NewHead message received
# from the consensus-layer.
proc reachTTD*(m: MergerRef) =
  if m.status.leftPoW:
    return

  m.status = TransitionStatus(leftPoW: true)
  m.db.writeStatus(m.status)

  info "Left PoW stage"

# FinalizePoS is called whenever the first FinalisedBlock message received
# from the consensus-layer.
proc finalizePoS*(m: MergerRef) =
  if m.status.enteredPoS:
    return

  m.status = TransitionStatus(leftPoW: true, enteredPoS: true)
  m.db.writeStatus(m.status)

  info "Entered PoS stage"

# TTDReached reports whether the chain has left the PoW stage.
proc ttdReached*(m: MergerRef): bool =
   m.status.leftPoW

# PoSFinalized reports whether the chain has entered the PoS stage.
proc posFinalized*(m: MergerRef): bool =
  m.status.enteredPoS
