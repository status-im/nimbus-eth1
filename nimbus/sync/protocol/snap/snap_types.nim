# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  chronicles,
  eth/common,
  ../../../constants

{.push raises: [].}

type
  SnapAccount* = object
    accHash*: Hash256
    accBody* {.rlpCustomSerialization.}: Account

  SnapProof* = object
    data* {.rlpCustomSerialization.}: Blob

  SnapStorage* = object
    slotHash*: Hash256
    slotData*: Blob

  SnapWireBase* = ref object of RootRef

  SnapPeerState* = ref object of RootRef

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
    T: type Blob;
      ): T
      {.gcsafe, raises: [RlpError]} =
  ## Rlp decoding for a proof node.
  rlp.read Blob

proc snapAppend*(
    writer: var RlpWriter;
    proofNode: Blob;
      ) =
  ## Rlp encoding for proof node.
  var start = 0u8

  # Need some magic to strip an extra layer that will be re-introduced by
  # the RLP encoder as object wrapper. The problem is that the `proofNode`
  # argument blob is encoded already and a second encoding must be avoided.
  #
  # This extra work is not an issue as the number of proof nodes in a list
  # is typically small.

  if proofNode.len < 57:
    # <c0> + data(max 55)
    start = 1u8
  elif 0xf7 < proofNode[0]:
    # <f7+sizeLen> + size + data ..
    start = proofNode[0] - 0xf7 + 1
  else:
    # Oops, unexpected data -- encode as is
    discard

  writer.appendRawBytes proofNode[start ..< proofNode.len]

# ------------------------------------------------------------------------------
# Public service stubs
# ------------------------------------------------------------------------------

proc notImplemented(name: string) =
  debug "Method not implemented", meth = name

method getAccountRange*(
    ctx: SnapWireBase;
    root: Hash256;
    origin: Hash256;
    limit: Hash256;
    replySizeMax: uint64;
      ): (seq[SnapAccount], seq[SnapProof])
      {.base, raises: [CatchableError].} =
  notImplemented("getAccountRange")

method getStorageRanges*(
    ctx: SnapWireBase;
    root: Hash256;
    accounts: openArray[Hash256];
    origin: openArray[byte];
    limit: openArray[byte];
    replySizeMax: uint64;
      ): (seq[seq[SnapStorage]], seq[SnapProof])
      {.base.} =
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
