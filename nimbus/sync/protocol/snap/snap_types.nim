# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[hashes, sequtils],
  results,
  chronicles,
  eth/common,
  ../../../constants

logScope:
  topics = "snap-wire"

type
  SnapAccount* = object
    accHash*: Hash32
    accBody* {.rlpCustomSerialization.}: Account

  SnapProof* = distinct seq[byte]
    ## Rlp coded node data, to be handled different from a generic `Blob`

  SnapProofNodes* = object
    ## Wrapper around `seq[SnapProof]` for controlling serialisation.
    nodes*: seq[SnapProof]

  SnapStorage* = object
    slotHash*: Hash32
    slotData*: seq[byte]

  SnapTriePaths* = object
    accPath*: seq[byte]
    slotPaths*: seq[seq[byte]]

  SnapWireBase* = ref object of RootRef

  SnapPeerState* = ref object of RootRef

# ------------------------------------------------------------------------------
# Public `SnapProof` type helpers
# ------------------------------------------------------------------------------

proc to*(data: seq[byte]; T: type SnapProof): T = data.T
proc to*(node: SnapProof; T: type seq[byte]): T = node.T

proc hash*(sp: SnapProof): Hash =
  ## Mixin for Table/HashSet
  sp.to(seq[byte]).hash

proc `==`*(a,b: SnapProof): bool =
  ## Mixin for Table/HashSet
  a.to(seq[byte]) == b.to(seq[byte])

# ------------------------------------------------------------------------------
# Public serialisation helpers
# ------------------------------------------------------------------------------

# The `snap` protocol represents `Account` differently from the regular RLP
# serialisation used in `eth` protocol as well as the canonical Merkle hash
# over all accounts.  In `snap`, empty storage hash and empty code hash are
# each represented by an RLP zero-length string instead of the full hash.  This
# avoids transmitting these hashes in about 90% of accounts.  We need to
# recognise or set these hashes in `Account` when serialising RLP for `snap`.

proc snapRead*(
    rlp: var Rlp;
    T: type Account;
    strict: static[bool] = false;
      ): T
      {.gcsafe, raises: [RlpError]} =
  ## RLP decoding for `Account`. The `snap` RLP representation of the account
  ## differs from standard `Account` RLP. Empty storage hash and empty code
  ## hash are each represented by an RLP zero-length string instead of the
  ## full hash.
  ##
  ## Normally, this read function will silently handle standard encodinig and
  ## `snap` enciding. Setting the argument strict as `false` the function will
  ## throw an exception if `snap` encoding is violated.
  rlp.tryEnterList()
  result.nonce = rlp.read(typeof(result.nonce))
  result.balance = rlp.read(typeof(result.balance))
  if rlp.blobLen != 0 or not rlp.isBlob:
    result.storageRoot = rlp.read(typeof(result.storageRoot))
    when strict:
      if result.storageRoot == EMPTY_ROOT_HASH:
        raise newException(RlpTypeMismatch,
          "EMPTY_ROOT_HASH not encoded as empty string in Snap protocol")
  else:
    rlp.skipElem()
    result.storageRoot = EMPTY_ROOT_HASH
  if rlp.blobLen != 0 or not rlp.isBlob:
    result.codeHash = rlp.read(typeof(result.codeHash))
    when strict:
      if result.codeHash == EMPTY_CODE_HASH:
        raise newException(RlpTypeMismatch,
          "EMPTY_SHA3 not encoded as empty string in Snap protocol")
  else:
    rlp.skipElem()
    result.codeHash = EMPTY_CODE_HASH

proc snapAppend*(
    writer: var RlpWriter;
    account: Account;
      ) =
  ## RLP encoding for `Account`. The snap RLP representation of the account
  ## differs from standard `Account` RLP. Empty storage hash and empty code
  ## hash are each represented by an RLP zero-length string instead of the
  ## full hash.
  writer.startList(4)
  writer.append(account.nonce)
  writer.append(account.balance)
  if account.storageRoot == EMPTY_ROOT_HASH:
    writer.append("")
  else:
    writer.append(account.storageRoot)
  if account.codeHash == EMPTY_CODE_HASH:
    writer.append("")
  else:
    writer.append(account.codeHash)

# ---------------------

proc snapRead*(
    rlp: var Rlp;
    T: type SnapProofNodes;
      ): T
      {.gcsafe, raises: [RlpError].} =
  ## RLP decoding for a wrapped `SnapProof` sequence. This extra wrapper is
  ## needed as the `SnapProof` items are `Blob` items at heart which is also
  ## the serialised destination data type.
  if rlp.isList:
    for w in rlp.items:
      result.nodes.add w.rawData.toSeq.to(SnapProof)
  elif rlp.isBlob:
    result.nodes.add rlp.rawData.toSeq.to(SnapProof)

proc snapAppend*(writer: var RlpWriter; spn: SnapProofNodes) =
  ## RLP encoding for a wrapped `SnapProof` sequence. This extra wrapper is
  ## needed as the `SnapProof` items are `Blob` items at heart which is also
  ## the serialised destination data type.
  writer.startList spn.nodes.len
  for w in spn.nodes:
    writer.appendRawBytes w.to(seq[byte])

# ---------------------

proc snapRead*(
    rlp: var Rlp;
    T: type SnapTriePaths;
      ): T
      {.gcsafe, raises: [RlpError].} =
  ## RLP decoding
  if not rlp.isList:
    raise newException(RlpTypeMismatch, "List expected")
  var first = true
  for w in rlp.items:
    if first:
      result.accPath = rlp.read(seq[byte])
      first = false
    else:
      result.slotPaths.add rlp.read(seq[byte])

proc snapAppend*(writer: var RlpWriter; stn: SnapTriePaths) =
  ## RLP encoding
  writer.startList(1 + stn.slotPaths.len)
  writer.append(stn.accPath)
  for w in stn.slotPaths:
    writer.append(w)

# ------------------------------------------------------------------------------
# Public service stubs
# ------------------------------------------------------------------------------

proc notImplemented(name: string) =
  debug "Method not implemented", meth = name

method getAccountRange*(
    ctx: SnapWireBase;
    root: Hash32;
    origin: openArray[byte];
    limit: openArray[byte];
    replySizeMax: uint64;
      ): Result[(seq[SnapAccount], SnapProofNodes), string]
      {.base, gcsafe.} =
  notImplemented("getAccountRange")

method getStorageRanges*(
    ctx: SnapWireBase;
    root: Hash32;
    accounts: openArray[Hash32];
    origin: openArray[byte];
    limit: openArray[byte];
    replySizeMax: uint64;
      ): Result[(seq[seq[SnapStorage]], SnapProofNodes), string]
      {.base, gcsafe.} =
  notImplemented("getStorageRanges")

method getByteCodes*(
    ctx: SnapWireBase;
    nodes: openArray[Hash32];
    replySizeMax: uint64;
      ): Result[seq[seq[byte]], string]
      {.base, gcsafe.} =
  notImplemented("getByteCodes")

method getTrieNodes*(
    ctx: SnapWireBase;
    root: Hash32;
    pathGroups: openArray[SnapTriePaths];
    replySizeMax: uint64;
      ): Result[seq[seq[byte]], string]
      {.base, gcsafe.} =
  notImplemented("getTrieNodes")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
