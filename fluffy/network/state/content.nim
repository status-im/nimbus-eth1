# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# https://github.com/ethereum/stateless-ethereum-specs/blob/master/state-network.md#content

{.push raises: [Defect].}

import
  std/[options, sugar],
  nimcrypto/[sha2, hash], stew/objects,
  eth/ssz/ssz_serialization, eth/trie/[hexary, db]

export ssz_serialization

type
  ByteList* = List[byte, 2048]

  ContentType* = enum
    Account = 0x01
    ContractStorage = 0x02
    ContractBytecode = 0x03

  NetworkId* = uint16

  NodeHash* = MDigest[32 * 8] # keccak256

  CodeHash* = MDigest[32 * 8] # keccak256

  Address* = array[20, byte]

  ContentKey* = object
    networkId*: NetworkId
    contentType*: ContentType
    # TODO: How shall we deal with the different ContentKey structures?
    # Lets start with just node hashes for now.
    # address: Address
    # triePath: ByteList
    nodeHash*: NodeHash

  ContentId* = MDigest[32 * 8]

  KeccakHash* = MDigest[32 * 8] # could also import from either eth common types or trie defs

template toSszType*(x: ContentType): uint8 =
  uint8(x)

template toSszType*(x: auto): auto =
  x

func fromSszBytes*(T: type ContentType, data: openArray[byte]):
    T {.raises: [MalformedSszError, Defect].} =
  if data.len != sizeof(uint8):
    raiseIncorrectSize T

  var contentType: T
  if not checkedEnumAssign(contentType, data[0]):
    raiseIncorrectSize T

  contentType

func encodeKey*(contentKey: ContentKey): seq[byte] =
  SSZ.encode(contentKey)

# TODO consider if more powerfull error handling is necessary here.
func decodeKey*(contentKey: ByteList): Option[ContentKey] = 
  try:
    some(SSZ.decode(contentKey.asSeq(), ContentKey))
  except SszError:
    return none[ContentKey]()

func encodeKeyAsList*(contentKey: ContentKey): ByteList =
  List.init(encodeKey(contentKey), 2048)

func toContentId*(contentKey: ByteList): ContentId =
  # TODO: Hash function to be defined, sha256 used now, might be confusing
  # with keccak256 that is used for the actual nodes:
  # https://github.com/ethereum/stateless-ethereum-specs/blob/master/state-network.md#content
  sha2.sha_256.digest(contentKey.asSeq())

type
  ContentStorage* = object
    # TODO: Quick implementation for now where we just use HexaryTrie, current
    # idea is to move in here a more direct storage of the trie nodes, but have
    # an `ContentProvider` "interface" that could provide the trie nodes via
    # this direct storage, via the HexaryTrie (for full nodes), or also without
    # storage, via json rpc client requesting data from a full eth1 client.
    trie*: HexaryTrie

proc getContent*(storage: ContentStorage, key: ContentKey): Option[seq[byte]] =
  if storage.trie.db == nil: # TODO: for now...
    return none(seq[byte])
  let val = storage.trie.db.get(key.nodeHash.data)
  if val.len > 0:
    some(val)
  else:
    none(seq[byte])

proc getContent*(storage: ContentStorage, contentKey: ByteList): Option[seq[byte]] =
  decodeKey(contentKey).flatMap((key: ContentKey) => getContent(storage, key))
