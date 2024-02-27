# nimbus-eth1
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Stackable API for `Kvt`
## =======================

import
  eth/common,
  results,
  "."/[kvt_desc, kvt_init, kvt_tx, kvt_utils]

# Annotation helper(s)
{.pragma: noRaise, gcsafe, raises: [].}
{.pragma: asFunc, gcsafe, raises: [], noSideEffect.}

type
  KvtApiBeginFn* = proc(db: KvtDbRef): Result[KvtTxRef,KvtError] {.noRaise.}
  KvtApiCommitFn* = proc(tx: KvtTxRef): Result[void,KvtError] {.noRaise.}
  KvtApiDelFn* = proc(db: KvtDbRef,
    key: openArray[byte]): Result[void,KvtError] {.noRaise.}
  KvtApiFinishFn* = proc(db: KvtDbRef, flush = false) {.noRaise.}
  KvtApiForgetFn* = proc(db: KvtDbRef): Result[void,KvtError] {.noRaise.}
  KvtApiForkFn* = proc(db: KvtDbRef): Result[KvtDbRef,KvtError] {.noRaise.}
  KvtApiForkTopFn* = proc(db: KvtDbRef): Result[KvtDbRef,KvtError] {.noRaise.}
  KvtApiGetFn* = proc(db: KvtDbRef,
    key: openArray[byte]): Result[Blob,KvtError] {.noRaise.}
  KvtApiHasKeyFn* = proc(db: KvtDbRef,
    key: openArray[byte]): Result[bool,KvtError] {.noRaise.}
  KvtApiIsTopFn* = proc(tx: KvtTxRef): bool {.asFunc.}
  KvtApiLevelFn* = proc(db: KvtDbRef): int {.asFunc.}
  KvtApiNForkedFn* = proc(db: KvtDbRef): int {.asFunc.}
  KvtApiPutFn* = proc(db: KvtDbRef,
    key, data: openArray[byte]): Result[void,KvtError] {.noRaise.}
  KvtApiRollbackFn* = proc(tx: KvtTxRef): Result[void,KvtError] {.noRaise.}
  KvtApiStowFn* = proc(db: KvtDbRef): Result[void,KvtError] {.noRaise.}
  KvtApiTxTopFn* =
    proc(db: KvtDbRef): Result[KvtTxRef,KvtError] {.asFunc.}

  KvtApiRef* = ref KvtApiObj
  KvtApiObj* = object of RootObj
    ## Useful set of `Kvt` fuctions that can be filtered, stacked etc. Note
    ## that this API is modelled after a subset of the `Aristo` API.
    commit*: KvtApiCommitFn
    del*: KvtApiDelFn
    finish*: KvtApiFinishFn
    forget*: KvtApiForgetFn
    fork*: KvtApiForkFn
    forkTop*: KvtApiForkTopFn
    get*: KvtApiGetFn
    hasKey*: KvtApiHasKeyFn
    isTop*: KvtApiIsTopFn
    level*: KvtApiLevelFn
    nForked*: KvtApiNForkedFn
    put*: KvtApiPutFn
    rollback*: KvtApiRollbackFn
    stow*: KvtApiStowFn
    txBegin*: KvtApiBeginFn
    txTop*: KvtApiTxTopFn

proc init*(api: var KvtApiObj) =
    api.commit = commit
    api.del = del
    api.finish = finish
    api.forget = forget
    api.fork = fork
    api.forkTop = forkTop
    api.get = get
    api.hasKey = hasKey
    api.isTop = isTop
    api.level = level
    api.nForked = nForked
    api.put = put
    api.rollback = rollback
    api.stow = stow
    api.txBegin = txBegin
    api.txTop = txTop

proc init*(T: type KvtApiRef): T =
  result = new T
  result[].init()

proc dup*(api: KvtApiRef): KvtApiRef =
  new result
  result[] = api[]

# End
