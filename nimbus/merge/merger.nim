import
  chronicles,
  eth/[rlp, trie/db],
  ../db/[storage_types, db_chain]

type
  # transitionStatus describes the status of eth1/2 transition. This switch
  # between modes is a one-way action which is triggered by corresponding
  # consensus-layer message.
  TransitionStatus = object
    leftPoW   : bool # The flag is set when the first NewHead message received
    enteredPoS: bool # The flag is set when the first FinalisedBlock message received

  # Merger is an internal help structure used to track the eth1/2 transition status.
  # It's a common structure can be used in both full node and light client.
  Merger* = object
    db    : TrieDatabaseRef
    status: TransitionStatus

proc write(db: TrieDatabaseRef, status: TransitionStatus) =
  db.put(transitionStatusKey().toOpenArray(), rlp.encode(status))

proc read(db: TrieDatabaseRef, status: var TransitionStatus) =
  var bytes = db.get(transitionStatusKey().toOpenArray())
  if bytes.len > 0:
    try:
      status = rlp.decode(bytes, typeof status)
    except:
      error "Failed to decode transition status"

proc init*(m: var Merger, db: TrieDatabaseRef) =
  m.db = db
  db.read(m.status)

proc init*(m: var Merger, db: BaseChainDB) =
  init(m, db.db)

proc initMerger*(db: BaseChainDB): Merger =
  result.init(db)

proc initMerger*(db: TrieDatabaseRef): Merger =
  result.init(db)

# ReachTTD is called whenever the first NewHead message received
# from the consensus-layer.
proc reachTTD*(m: var Merger) =
  if m.status.leftPoW:
    return

  m.status = TransitionStatus(leftPoW: true)
  m.db.write(m.status)

  info "Left PoW stage"

# FinalizePoS is called whenever the first FinalisedBlock message received
# from the consensus-layer.
proc finalizePoS*(m: var Merger) =
  if m.status.enteredPoS:
    return

  m.status = TransitionStatus(leftPoW: true, enteredPoS: true)
  m.db.write(m.status)

  info "Entered PoS stage"

# TTDReached reports whether the chain has left the PoW stage.
proc ttdReached*(m: Merger): bool =
   m.status.leftPoW

# PoSFinalized reports whether the chain has entered the PoS stage.
proc posFinalized*(m: Merger): bool =
  m.status.enteredPoS
