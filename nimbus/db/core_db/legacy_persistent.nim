# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  eth/trie/db,
  ../select_backend,
  "."/[base, legacy]

export
  toLegacyTrieRef

type
  LegaPersDbRef = ref object of LegacyDbRef
    backend: ChainDB     # for backend access (legacy mode)

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template iflegaPersOk(db: CoreDbRef; body: untyped) =
  case db.dbType:
  of LegacyDbPersistent:
    body
  else:
    discard

# ------------------------------------------------------------------------------
# Public constructor and low level data retrieval, storage & transation frame
# ------------------------------------------------------------------------------

proc newLegacyPersistentCoreDbRef*(path: string): CoreDbRef =
  # Kludge: Compiler bails out on `results.tryGet()` with
  # ::
  #   fatal.nim(54)            sysFatal
  #   Error: unhandled exception: types.nim(1251, 10) \
  #     `b.kind in {tyObject} + skipPtrs`  [AssertionDefect]
  #
  # when running `select_backend.newChainDB(path)`. The culprit seems to be
  # the `ResultError` exception (or any other `CatchableError`). So this is
  # converted to a `Defect`.
  var backend: ChainDB
  try:
    {.push warning[Deprecated]: off.}
    backend = newChainDB path
    {.pop.}
  except CatchableError as e:
    let msg = "DB initialisation error(" & $e.name & "): " & e.msg
    raise (ref ResultDefect)(msg: msg)
  LegaPersDbRef(backend: backend).init(LegacyDbPersistent, backend.trieDB)

# ------------------------------------------------------------------------------
# Public legacy helpers
# ------------------------------------------------------------------------------

proc toLegacyBackend*(db: CoreDbRef): ChainDB =
  db.ifLegaPersOk:
    return db.LegaPersDbRef.backend

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
