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
  eth/common

{.push raises: [].}

type
  SnapAccount* = object
    accHash*: Hash256
    accBody* {.rlpCustomSerialization.}: Account

  SnapAccountProof* = seq[Blob]

  SnapStorage* = object
    slotHash*: Hash256
    slotData*: Blob

  SnapStorageProof* = seq[Blob]

  SnapWireBase* = ref object of RootRef

  SnapPeerState* = ref object of RootRef

proc notImplemented(name: string) =
  debug "Method not implemented", meth = name

method getAccountRange*(
    ctx: SnapWireBase;
    root: Hash256;
    origin: Hash256;
    limit: Hash256;
    replySizeMax: uint64;
      ): (seq[SnapAccount], SnapAccountProof)
      {.base.} =
  notImplemented("getAccountRange")

method getStorageRanges*(
    ctx: SnapWireBase;
    root: Hash256;
    accounts: openArray[Hash256];
    origin: openArray[byte];
    limit: openArray[byte];
    replySizeMax: uint64;
      ): (seq[seq[SnapStorage]], SnapStorageProof)
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

# End
