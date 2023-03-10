# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
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
  chronicles,
  eth/common,
  ../../../constants

logScope:
  topics = "snap-wire"

type
  SnapAccount* = object
    accHash*: Hash256
    accBody* {.rlpCustomSerialization.}: Account

  SnapProof* = distinct Blob
    ## Rlp coded node data, to be handled different from a generic `Blob`

  SnapProofNodes* = object
    ## Wrapper around `seq[SnapProof]` for controlling serialisation.
    nodes*: seq[SnapProof]

  SnapStorage* = object
    slotHash*: Hash256
    slotData*: Blob

  SnapWireBase* = ref object of RootRef

  SnapPeerState* = ref object of RootRef

# ------------------------------------------------------------------------------
# Public `SnapProof` type helpers
# ------------------------------------------------------------------------------

proc to*(data: Blob; T: type SnapProof): T = data.T
proc to*(node: SnapProof; T: type Blob): T = node.T

proc hash*(sp: SnapProof): Hash =
  ## Mixin for Table/HashSet
  sp.to(Blob).hash

proc `==`*(a,b: SnapProof): bool =
  ## Mixin for Table/HashSet
  a.to(Blob) == b.to(Blob)

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
      if result.codeHash == EMPTY_SHA3:
        raise newException(RlpTypeMismatch,
          "EMPTY_SHA3 not encoded as empty string in Snap protocol")
  else:
    rlp.skipElem()
    result.codeHash = EMPTY_SHA3

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
  if account.codeHash == EMPTY_SHA3:
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
    writer.appendRawBytes w.to(Blob)

# ------------------------------------------------------------------------------
# Public service stubs
# ------------------------------------------------------------------------------

proc notImplemented(name: string) =
  debug "Method not implemented", meth = name

method getAccountRange*(
    ctx: SnapWireBase;
    root: Hash256;
    origin: openArray[byte];
    limit: openArray[byte];
    replySizeMax: uint64;
      ): (seq[SnapAccount], SnapProofNodes)
      {.base, raises: [CatchableError].} =
  notImplemented("getAccountRange")

method getStorageRanges*(
    ctx: SnapWireBase;
    root: Hash256;
    accounts: openArray[Hash256];
    origin: openArray[byte];
    limit: openArray[byte];
    replySizeMax: uint64;
      ): (seq[seq[SnapStorage]], SnapProofNodes)
      {.base, raises: [CatchableError].} =
  notImplemented("getStorageRanges")

method getByteCodes*(
    ctx: SnapWireBase;
    nodes: openArray[Hash256];
    replySizeMax: uint64;
      ): seq[Blob]
      {.base.} =
  notImplemented("getByteCodes")

method getTrieNodes*(
    ctx: SnapWireBase;
    root: Hash256;
    paths: openArray[seq[Blob]];
    replySizeMax: uint64;
      ): seq[Blob]
      {.base.} =
  notImplemented("getTrieNodes")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
