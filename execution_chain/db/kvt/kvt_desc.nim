# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- key-value table
## =========================
##
{.push raises: [].}

import
  std/[hashes, tables],
  eth/common/[base, hashes],
  results,
  ./kvt_init/init_common,
  ./kvt_constants,
  ./kvt_desc/desc_error

when compileOption("threads"):
  import ../../concurrency/lru
  export lru

# Not auto-exporting backend
export hashes, tables, kvt_constants, desc_error

type
  GetKvpFn* =
    proc(key: openArray[byte]): Result[seq[byte], KvtError] {.gcsafe, raises: [].}
    ## Generic backend database retrieval function

  LenKvpFn* = proc(key: openArray[byte]): Result[int, KvtError] {.gcsafe, raises: [].}
    ## Generic backend database retrieval function

  MultiGetKvpFn* = proc(
    keys: openArray[seq[byte]], values: var openArray[Opt[seq[byte]]], sortedInput: bool
  ): Result[void, KvtError] {.gcsafe, raises: [].}
    ## Generic backend database bulk retrieval function

  PutKvpFn* = proc(k, v: openArray[byte]): Result[void, KvtError] {.gcsafe, raises: [].}
    ## Generic backend database storage function.

  DelKvpFn* = proc(key: openArray[byte]): Result[void, KvtError] {.gcsafe, raises: [].}
    ## Generic backend database delete function.

  DelRangeKvpFn* = proc(
    startKey, endKey: openArray[byte], compactRange: bool
  ): Result[void, KvtError] {.gcsafe, raises: [].}
    ## Generic backend database bulk delete function.

  # -------------

  CloseFn* = proc(wipe: bool) {.gcsafe, raises: [].}
    ## Generic destructor for the `Kvt DB` backend. The argument `wipe`
    ## indicates that a full database deletion is requested. If passed
    ## `false` the outcome might differ depending on the type of backend
    ## (e.g. in-memory backends would wipe on close.)

  # -------------

  GetBackendFn* = proc(): TypedBackendRef {.gcsafe, raises: [].}
    ## Get a reference to typed backend.

  KvtDbRef* = ref object of RootRef ## Backend interface.
    getKvpFn*: GetKvpFn ## Read key-value pair
    lenKvpFn*: LenKvpFn ## Read key-value pair length
    multiGetKvpFn*: MultiGetKvpFn ## Bulk read key-value pairs

    putKvpFn*: PutKvpFn ## Store key-value pairs

    delKvpFn*: DelKvpFn ## Delete key-value pair
    delRangeKvpFn*: DelRangeKvpFn ## Bulk delete key-value pairs

    closeFn*: CloseFn ## Generic destructor

    getBackendFn*: GetBackendFn

    when compileOption("threads"):
      blockHashes*: ConcurrentLruCache[BlockNumber, Hash32]
        ## Block number to block hash cache mirroring the backend

# ------------------------------------------------------------------------------
# Public constructor helpers
# ------------------------------------------------------------------------------

proc initInstance*(
    db: KvtDbRef, threadSafeCaches = true, blockHashesLruSize = 0) =
  when compileOption("threads"):
    if threadSafeCaches:
      db.blockHashes.init(blockHashesLruSize)
    else:
      db.blockHashes.init(blockHashesLruSize, shardBits = 0, threadSafe = false)

proc disposeInstance*(db: KvtDbRef) =
  when compileOption("threads"):
    db.blockHashes.dispose()
    db.blockHashes.reset()

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func isValid*(key: seq[byte]): bool =
  key != EmptyBlob

# ------------------------------------------------------------------------------
# Public functions, miscellaneous
# ------------------------------------------------------------------------------

# Don't put in a hash!
func hash*(db: KvtDbRef): Hash {.error.}

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
