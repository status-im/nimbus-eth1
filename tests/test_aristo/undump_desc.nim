# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.push raises: [].}

import
  eth/common,
  stint,
  ../../execution_chain/sync/protocol

## Stripped down version of `sync/snap/range_desc` in order to decode the
## snap sync dump samples.
##
## While the details of the dumped data have mostly outlived their purpuse,
## its use as **entropy** data thrown against `Aristo` has still been useful
## to find/debug tricky DB problems.

type
  ByteArray32* = array[32,byte]
    ## Used for 32 byte database keys

  NodeKey* = distinct ByteArray32
    ## Hash key without the hash wrapper (as opposed to `NodeTag` which is a
    ## number.)

  NodeTag* = distinct UInt256
    ## Trie leaf item, account hash etc. This data type is a representation
    ## for a `NodeKey` geared up for arithmetic and comparing keys.

  PackedAccountRange* = object
    ## Re-packed version of `SnapAccountRange`. The reason why repacking is
    ## needed is that the `snap/1` protocol uses another RLP encoding than is
    ## used for storing in the database. So the `PackedAccount` is `BaseDB`
    ## trie compatible.
    accounts*: seq[PackedAccount]  ## List of re-packed accounts data
    proof*: seq[SnapProof]         ## Boundary proofs

  PackedAccount* = object
    ## In fact, the `snap/1` driver returns the `Account` structure which is
    ## unwanted overhead, here.
    accKey*: NodeKey
    accBlob*: seq[byte]

  AccountSlotsHeader* = object
    ## Storage root header
    accKey*: NodeKey                ## Owner account, maybe unnecessary
    storageRoot*: Hash32            ## Start of storage tree
    #subRange*: Opt[NodeTagRange]    ## Sub-range of slot range covered

  AccountStorageRange* = object
    ## List of storage descriptors, the last `AccountSlots` storage data might
    ## be incomplete and the `proof` is needed for proving validity.
    storages*: seq[AccountSlots]    ## List of accounts and storage data
    proof*: seq[SnapProof]          ## Boundary proofs for last entry
    base*: NodeTag                  ## Lower limit for last entry w/proof

  AccountSlots* = object
    ## Account storage descriptor
    account*: AccountSlotsHeader
    data*: seq[SnapStorage]


proc to*(tag: NodeTag; T: type Hash32): T =
  ## Convert to serialised equivalent
  result.data = tag.UInt256.toBytesBE

proc to*(key: Hash32; T: type NodeTag): T =
  ## Syntactic sugar
  key.data.NodeKey.to(T)

proc to*(key: NodeKey; T: type NodeTag): T =
  ## Convert from serialised equivalent
  UInt256.fromBytesBE(key.ByteArray32).T

# End
