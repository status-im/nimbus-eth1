# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/strutils,
  stew/byteutils,
  beacon_chain/spec/engine_types,
  beacon_chain/spec/presets,
  beacon_chain/spec/datatypes/[bellatrix, capella, deneb, gloas]

from beacon_chain/spec/datatypes/fulu import BYTES_PER_CELL
from ../stateless/stateless_types import PUBLIC_KEY_BYTES

export engine_types, presets, BYTES_PER_CELL, PUBLIC_KEY_BYTES

func optSome*[T](x: T): Optional[T] =
  Optional[T].init(@[x])

func optNone*(T: typedesc): Optional[T] =
  default(Optional[T])

func isSome*[T](o: Optional[T]): bool =
  o.len > 0

func get*[T](o: Optional[T]): T =
  o[0]

type
  StringSsz* = EngineString

func toStringSsz*(s: string): StringSsz =
  StringSsz.init(s.toBytes)

func toString*(s: StringSsz): string =
  string.fromBytes(asSeq(s))

func parseEngineFork*(s: string): Opt[EngineFork] =
  try:
    Opt.some(parseEnum[EngineFork](s))
  except ValueError:
    Opt.none(EngineFork)

const
  # REMOVE WHEN DROPPING JSON-RPC
  PAYLOAD_STATUS_INVALID_BLOCK_HASH* = 4'u8

const
  MAX_BYTES_PER_TX* = 1 shl 30
  MAX_TXS_PER_PAYLOAD* = 1 shl 20
  MAX_BODIES_REQUEST* = 1 shl 5
  MAX_BAL_BYTES* = MAX_BYTES_PER_TX
  MAX_REQUEST_BODY_SIZE* = 64 * 1024 * 1024

  # POST /engine/v1/payloads/witness
  # https://github.com/ethereum/execution-apis/pull/885
  MAX_WITNESS_ITEMS* = 1 shl 20
  MAX_WITNESS_ITEM_BYTES* = 1 shl 20

type
  WitnessItem* = ByteList[Limit MAX_WITNESS_ITEM_BYTES]
  WitnessItems* = List[WitnessItem, Limit MAX_WITNESS_ITEMS]

  ExecutionWitness* = object
    ## TODO: Current spec PR keeps this fork invariant with transport
    ## local bounds, so a witness accepted here can still be unusable by
    ## the stateless guest. Propose fork scoping it and adopting those.
    state*: WitnessItems ## RLP encoded account and storage trie nodes
    codes*: WitnessItems ## Contract bytecode read from the pre state
    headers*: WitnessItems
      ## RLP encoded ancestor headers, oldest to newest, ending at the parent

  PublicKeys* = List[ByteVector[PUBLIC_KEY_BYTES], Limit MAX_TXS_PER_PAYLOAD]

  PayloadStatusWithWitness* = object
    payload_status*: engine_types.PayloadStatus
    witness*: Optional[ExecutionWitness]
    public_keys*: PublicKeys

  PayloadAttributesParis* = object
    timestamp*: uint64
    prev_randao*: Eth2Digest
    suggested_fee_recipient*: ExecutionAddress

  PayloadAttributesShanghai* = object
    timestamp*: uint64
    prev_randao*: Eth2Digest
    suggested_fee_recipient*: ExecutionAddress
    withdrawals*: Withdrawals

  PayloadAttributesCancun* = PayloadAttributesPrague

  ForkedPayloadAttributes* = object
    case fork*: EngineFork
    of EngineFork.Paris:
      parisData*: PayloadAttributesParis
    of EngineFork.Shanghai:
      shanghaiData*: PayloadAttributesShanghai
    of EngineFork.Cancun, EngineFork.Prague, EngineFork.Osaka:
      cancunData*: PayloadAttributesCancun
    of EngineFork.Amsterdam:
      amsterdamData*: PayloadAttributesAmsterdam

template withForkedAttributes*(x: ForkedPayloadAttributes, body: untyped): untyped =
  case x.fork
  of EngineFork.Paris:
    const fork {.inject, used.} = EngineFork.Paris
    template attrs: untyped {.inject, used.} = x.parisData
    body
  of EngineFork.Shanghai:
    const fork {.inject, used.} = EngineFork.Shanghai
    template attrs: untyped {.inject, used.} = x.shanghaiData
    body
  of EngineFork.Cancun, EngineFork.Prague, EngineFork.Osaka:
    const fork {.inject, used.} = EngineFork.Cancun
    template attrs: untyped {.inject, used.} = x.cancunData
    body
  of EngineFork.Amsterdam:
    const fork {.inject, used.} = EngineFork.Amsterdam
    template attrs: untyped {.inject, used.} = x.amsterdamData
    body

func timestamp*(x: ForkedPayloadAttributes): uint64 =
  withForkedAttributes(x): attrs.timestamp

type
  ForkchoiceUpdateParis* = object
    forkchoice_state*: ForkchoiceState
    payload_attributes*: Optional[PayloadAttributesParis]

  ForkchoiceUpdateShanghai* = object
    forkchoice_state*: ForkchoiceState
    payload_attributes*: Optional[PayloadAttributesShanghai]

  ForkchoiceUpdateCancun* = ForkchoiceUpdatePrague

  BuiltPayloadParis* = object
    payload*: bellatrix.ExecutionPayload
    block_value*: UInt256

  BuiltPayloadShanghai* = object
    payload*: capella.ExecutionPayload
    block_value*: UInt256

  BuiltPayloadCancun* = object
    payload*: deneb.ExecutionPayload
    block_value*: UInt256
    blobs_bundle*: BlobsBundleV1
    should_override_builder*: bool

  ExecutionPayloadBodyParis* = object
    transactions*: List[ByteList[Limit MAX_BYTES_PER_TX], Limit MAX_TXS_PER_PAYLOAD]

  ExecutionPayloadBodyShanghai* = object
    transactions*: List[ByteList[Limit MAX_BYTES_PER_TX], Limit MAX_TXS_PER_PAYLOAD]
    withdrawals*: Withdrawals

  ExecutionPayloadBodyCancun* = ExecutionPayloadBodyShanghai
  ExecutionPayloadBodyPrague* = ExecutionPayloadBodyShanghai
  ExecutionPayloadBodyOsaka* = ExecutionPayloadBodyShanghai

  ExecutionPayloadBodyAmsterdam* = object
    transactions*: List[ByteList[Limit MAX_BYTES_PER_TX], Limit MAX_TXS_PER_PAYLOAD]
    withdrawals*: Withdrawals
    block_access_list*: ByteList[Limit MAX_BAL_BYTES]

  BodiesByHashRequest* = object
    block_hashes*: List[Eth2Digest, Limit MAX_BODIES_REQUEST]

  BodyEntryParis* = object
    available*: bool
    body*: ExecutionPayloadBodyParis

  BodyEntryShanghai* = object
    available*: bool
    body*: ExecutionPayloadBodyShanghai

  BodyEntryCancun* = BodyEntryShanghai
  BodyEntryPrague* = BodyEntryShanghai
  BodyEntryOsaka* = BodyEntryShanghai

  BodyEntryAmsterdam* = object
    available*: bool
    body*: ExecutionPayloadBodyAmsterdam

  BodiesResponseParis* = object
    entries*: List[BodyEntryParis, Limit MAX_BODIES_REQUEST]

  BodiesResponseShanghai* = object
    entries*: List[BodyEntryShanghai, Limit MAX_BODIES_REQUEST]

  BodiesResponseCancun* = BodiesResponseShanghai
  BodiesResponsePrague* = BodiesResponseShanghai
  BodiesResponseOsaka* = BodiesResponseShanghai

  BodiesResponseAmsterdam* = object
    entries*: List[BodyEntryAmsterdam, Limit MAX_BODIES_REQUEST]

  BlobAndProofV1* = object
    blob*: deneb.Blob
    proof*: deneb.KzgProof

  BlobV1Entry* = object
    available*: bool
    contents*: BlobAndProofV1

  BlobsV1Response* = object
    entries*: List[BlobV1Entry, Limit MAX_BLOBS_REQUEST]

  BlobV3Entry* = BlobV2Entry

  BlobsV3Response* = object
    entries*: List[BlobV3Entry, Limit MAX_BLOBS_REQUEST]
