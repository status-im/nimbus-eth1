# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  pkg/eth/common,
  pkg/results

type
  EdgeDbError* = enum
    ## Allows more granulated failure information.
    NothingSerious = 0
    EdgeKeyNotFound
    EdgeColUnsupported
    EdgeKeyTypeUnsupported

  EdgeDbColumn* = enum
    ## Specify object type to query for
    Oops = 0
    EthBlockData
    EthHeaderData
    EthBodyData

  EdgeDbGetRef* = ref object of RootObj
    ## Descriptor common to a set of `getFn()` implementations. This basic type
    ## will be interited by sprcific implementations.


  EdgeDbUintGetFn* =
    proc(dsc: EdgeDbGetRef;
         col: EdgeDbColumn;
         key: uint64;
        ): Result[Blob,EdgeDbError]
        {.gcsafe, raises: [].}
      ## Particular `getFn()` instance. Will return a RLP encoded serialised
      ## data result.

  EdgeDbBlobGetFn* =
    proc(dsc: EdgeDbGetRef;
         col: EdgeDbColumn;
         key: openArray[byte];
        ): Result[Blob,EdgeDbError]
        {.gcsafe, raises: [].}
      ## Ditto for `Blob` like key


  EdgeDbUintGetPolicyFn* =
    proc(edg: EdgeDbRef;
         col: EdgeDbColumn;
         key: uint64;
        ): Result[Blob,EdgeDbError]
        {.gcsafe, raises: [].}
      ## Implemenation of `get()`. This function employs a set of `getFn()`
      ## instances (in some order) for finding a result.

  EdgeDbBlobGetPolicyFn* =
    proc(edg: EdgeDbRef;
         col: EdgeDbColumn;
         key: openArray[byte];
        ): Result[Blob,EdgeDbError]
        {.gcsafe, raises: [].}
      ##  Ditto for `Blob` like key


  EdgeDbRef* = ref object
    ## Visible database wrapper.
    getDesc*: EdgeDbGetRef
    uintGetFns*: seq[EdgeDbUintGetFn]
    blobGetFns*: seq[EdgeDbBlobGetFn]
    uintGetPolFn*: EdgeDbUintGetPolicyFn
    blobGetPolFn*: EdgeDbBlobGetPolicyFn

# ------------------------------------------------------------------------------
# Public helpers, sequentially trying a list of `getFn()` instances
# ------------------------------------------------------------------------------

proc uintGetSeqentiallyUntilFound*(
  edg: EdgeDbRef;
  col: EdgeDbColumn;
  key: uint64;
    ): Result[Blob,EdgeDbError] =
  ## Simple linear get policy.
  var error = EdgeColUnsupported

  for fn in edg.uintGetFns:
    let err = edg.getDesc.fn(col,key).errorOr:
      return ok(value)
    if err != EdgeColUnsupported:
      error = EdgeKeyNotFound

  err(error)

proc blobGetSeqentiallyUntilFound*(
  edg: EdgeDbRef;
  col: EdgeDbColumn;
  key: openArray[byte];
    ): Result[Blob,EdgeDbError] =
  ## Ditto for `Blob` like key
  var error = EdgeColUnsupported

  for fn in edg.blobGetFns:
    let err = edg.getDesc.fn(col,key).errorOr:
      return ok(value)
    if err != EdgeColUnsupported:
      error = EdgeKeyNotFound

  err(error)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
