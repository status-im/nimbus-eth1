# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# As per spec:
# https://github.com/ethereum/portal-network-specs/blob/master/state-network.md#content-keys-and-content-ids

{.push raises: [].}

import
  nimcrypto/[hash, sha2, keccak], stew/results, stint,
  eth/common/eth_types,
  ssz_serialization,
  ../../common/common_types

export ssz_serialization, common_types, hash, results

const
  MAX_PACKED_NIBBLES_LEN   = 33
  MAX_UNPACKED_NIBBLES_LEN = 64

  MAX_TRIE_NODE_LEN  = 1024
  MAX_TRIE_PROOF_LEN = 65
  MAX_BYTECODE_LEN   = 32768

type
  NodeHash* = KeccakHash
  CodeHash* = KeccakHash
  Address*  = EthAddress

  ContentType* = enum
    # Note: Need to add this unused value as a case object with an enum without
    # a 0 valueis not allowed: "low(contentType) must be 0 for discriminant".
    # For prefix values that are in the enum gap, the deserialization will fail
    # at runtime as is wanted.
    # In the future it might be possible that this will fail at compile time for
    # the SSZ Union type, but currently it is allowed in the implementation, and
    # the SSZ spec is not explicit about disallowing this.
    unused = 0x00
    accountTrieNode = 0x20
    contractTrieNode = 0x21
    contractCode = 0x22

  Nibbles* = List[byte, MAX_PACKED_NIBBLES_LEN]

  TrieNode*  = List[byte, MAX_TRIE_NODE_LEN]
  TrieProof* = List[TrieNode, MAX_TRIE_PROOF_LEN]

  Bytecode* = List[byte, MAX_BYTECODE_LEN]

  AccountTrieNodeKey* = object
    path*: Nibbles
    nodeHash*: NodeHash

  ContractTrieNodeKey* = object
    address*: Address
    path*: Nibbles
    nodeHash*: NodeHash

  ContractCodeKey* = object
    address*: Address
    codeHash*: CodeHash

  ContentKey* = object
    case contentType*: ContentType
    of unused:
      discard
    of accountTrieNode:
      accountTrieNodeKey*: AccountTrieNodeKey
    of contractTrieNode:
      contractTrieNodeKey*: ContractTrieNodeKey
    of contractCode:
      contractCodeKey*: ContractCodeKey

  AccountTrieNodeOffer* = object
    proof*: TrieProof
    blockHash*: BlockHash

  AccountTrieNodeRetrieval* = object
    node*: TrieNode

  ContractTrieNodeOffer* = object
    storageProof*: TrieProof
    accountProof*: TrieProof
    blockHash*: BlockHash

  ContractTrieNodeRetrieval* = object
    node*: TrieNode

  ContractCodeOffer* = object
    code*: Bytecode
    accountProof*: TrieProof
    blockHash*: BlockHash

  ContractCodeRetrieval* = object
    code*: Bytecode

  OfferContentValueType* = enum
    accountTrieNodeOffer,
    contractTrieNodeOffer,
    contractCodeOffer,

  OfferContentValue* = object
    case contentType*: ContentType
    of unused:
      discard
    of accountTrieNode:
      accountTrieNode*: AccountTrieNodeOffer
    of contractTrieNode:
      contractTrieNode*: ContractTrieNodeOffer
    of contractCode:
      contractCode*: ContractCodeOffer

  RetrievalContentValue* = object
    case contentType*: ContentType
    of unused:
      discard
    of accountTrieNode:
      accountTrieNode*: AccountTrieNodeRetrieval
    of contractTrieNode:
      contractTrieNode*: ContractTrieNodeRetrieval
    of contractCode:
      contractCode*: ContractCodeRetrieval

func encode*(contentKey: ContentKey): ByteList =
  doAssert(contentKey.contentType != unused)
  ByteList.init(SSZ.encode(contentKey))

proc readSszBytes*(
    data: openArray[byte], val: var ContentKey
) {.raises: [SszError].} =
  mixin readSszValue
  if data.len() > 0 and data[0] == ord(unused):
    raise newException(MalformedSszError, "SSZ selector is unused value")

  readSszValue(data, val)

func decode*(contentKey: ByteList): Opt[ContentKey] =
  try:
    Opt.some(SSZ.decode(contentKey.asSeq(), ContentKey))
  except SerializationError:
    return Opt.none(ContentKey)

func toContentId*(contentKey: ByteList): ContentId =
  # TODO: Should we try to parse the content key here for invalid ones?
  let idHash = sha2.sha256.digest(contentKey.asSeq())
  readUintBE[256](idHash.data)

func toContentId*(contentKey: ContentKey): ContentId =
  toContentId(encode(contentKey))

func offerContentToRetrievalContent*(offerContent: OfferContentValue): RetrievalContentValue =
  case offerContent.contentType:
    of unused:
      raiseAssert "Converting content with unused content type"
    of accountTrieNode:
      RetrievalContentValue(
        contentType: accountTrieNode,
        accountTrieNode: AccountTrieNodeRetrieval(node: offerContent.accountTrieNode.proof[^1])
        ) # TODO implement properly
    of contractTrieNode:
      RetrievalContentValue(
        contentType: contractTrieNode,
        contractTrieNode: ContractTrieNodeRetrieval(node: offerContent.contractTrieNode.storageProof[^1])
        ) # TODO implement properly
    of contractCode:
      RetrievalContentValue(
        contentType: contractCode,
        contractCode: ContractCodeRetrieval(code: offerContent.contractCode.code)
        )

func encode*(content: RetrievalContentValue): seq[byte] =
  case content.contentType:
    of unused:
      raiseAssert "Encoding content with unused content type"
    of accountTrieNode:
      SSZ.encode(content.accountTrieNode)
    of contractTrieNode:
      SSZ.encode(content.contractTrieNode)
    of contractCode:
      SSZ.encode(content.contractCode)

func decodeKV*(contentKey: ByteList, contentValue: seq[byte]): Opt[(ContentKey, OfferContentValue)] =
  const empty = Opt.none((ContentKey, OfferContentValue))
  let
    key = contentKey.decode().valueOr:
      return empty
    value = case key.contentType:
      of unused:
        return empty
      of accountTrieNode:
        let val = decodeSsz(contentValue, AccountTrieNodeOffer).valueOr:
          return empty
        OfferContentValue(contentType: accountTrieNode, accountTrieNode: val)
      of contractTrieNode:
        let val = decodeSsz(contentValue, ContractTrieNodeOffer).valueOr:
          return empty
        OfferContentValue(contentType: contractTrieNode, contractTrieNode: val)
      of contractCode:
        let val = decodeSsz(contentValue, ContractCodeOffer).valueOr:
          return empty
        OfferContentValue(contentType: contractCode, contractCode: val)

  Opt.some((key, value))

func packNibbles*(nibbles: seq[byte]): Nibbles =
  doAssert(nibbles.len() <= MAX_UNPACKED_NIBBLES_LEN, "Can't pack more than 64 nibbles")

  if nibbles.len() == 0:
    return Nibbles(@[byte(0x00)])
  
  let
    isOddLength = (nibbles.len() %% 2 == 1)
    outputLength = (nibbles.len() + 1) div 2

  var
    output = newSeq[byte]()
    highNibble = not isOddLength
    currentByte: byte = 0

  if isOddLength:
    currentByte = 0x10

  if not isOddLength:
    output.add(0x00)

  for i, nibble in nibbles:
    if highNibble:
      currentByte = nibble shl 4
    else:
      output.add(currentByte or nibble)
      currentByte = 0
    highNibble = not highNibble

  Nibbles(output)

func unpackNibbles*(nibbles: Nibbles): seq[byte] =
  doAssert(nibbles.len() <= MAX_PACKED_NIBBLES_LEN, "Packed nibbles length is too long")

  var output = newSeq[byte]()

  for i, pair in nibbles:
    if i == 0 and pair == 0x00:
      continue

    let
      first = (pair and 0xF0) shr 4
      second = pair and 0x0F

    if i == 0 and first == 0x01:
      output.add(second)
    else:
      output.add(first)
      output.add(second)

  output

