# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push gcsafe, raises: [].}

import
  chronicles,
  eth/rlp,
  results,
  ../db/[core_db, storage_types]

type
  # transitionStatus describes the status of eth1/2 transition. This switch
  # between modes is a one-way action which is triggered by corresponding
  # consensus-layer message.
  TransitionStatus = object
    # The flag is set when the first NewHead message received
    leftPoW   : bool

    # The flag is set when the first FinalisedBlock message received
    enteredPoS: bool

  # Merger is an internal help structure used to track the eth1/2
  # transition status. It's a common structure can be used in both full node
  # and light client.
  MergeTracker* = object
    db    : CoreDbRef
    status: TransitionStatus

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc writeStatus(db: CoreDbRef, status: TransitionStatus) =
  db.newKvt.put(transitionStatusKey().toOpenArray(), rlp.encode(status)).isOkOr:
    raiseAssert "writeStatus(): put() failed " & $$error

proc readStatus(db: CoreDbRef): TransitionStatus =
  var bytes = db.newKvt.get(transitionStatusKey().toOpenArray()).valueOr:
    EmptyBlob
  if bytes.len > 0:
    try:
      result = rlp.decode(bytes, typeof result)
    except CatchableError:
      error "Failed to decode POS transition status"

# ------------------------------------------------------------------------------
# Constructors
# ------------------------------------------------------------------------------

proc init*(_: type MergeTracker, db: CoreDbRef): MergeTracker =
  MergeTracker(
    db: db,
    status: db.readStatus()
  )

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc reachTTD*(m: var MergeTracker) =
  ## ReachTTD is called whenever the first NewHead message received
  ## from the consensus-layer.
  if m.status.leftPoW:
    return

  m.status = TransitionStatus(leftPoW: true)
  m.db.writeStatus(m.status)

  info "Left PoW stage"

proc finalizePoS*(m: var MergeTracker) =
  ## FinalizePoS is called whenever the first FinalisedBlock message received
  ## from the consensus-layer.

  if m.status.enteredPoS:
    return

  m.status = TransitionStatus(leftPoW: true, enteredPoS: true)
  m.db.writeStatus(m.status)

  info "Entered PoS stage"

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

func ttdReached*(m: MergeTracker): bool =
  ## TTDReached reports whether the chain has left the PoW stage.
  m.status.leftPoW

func posFinalized*(m: MergeTracker): bool =
  ## PoSFinalized reports whether the chain has entered the PoS stage.
  m.status.enteredPoS
