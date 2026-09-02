# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[strutils, tables],
  eth/common/[base, keys, headers, transactions, receipts],
  eth/bloom,
  stint,
  json_serialization,
  json_serialization/pkg/results,
  ../../execution_chain/transaction,
  ../../execution_chain/db/ledger,
  ../../execution_chain/common/chain_config,
  ../common/parsers

export
  parsers

type
  StateEnv* = object
    currentCoinbase*       : Opt[Address]
    currentDifficulty*     : Opt[DifficultyInt]
    currentNumber*         : Opt[BlockNumber]
    currentGasLimit*       : Opt[GasInt]
    currentTimestamp*      : Opt[EthTime]
    currentRandom*         : Opt[Bytes32]
    currentBaseFee*        : Opt[UInt256]
    currentWithdrawalsRoot*: Opt[Hash32]
    currentExcessBlobGas*  : Opt[uint64]
    currentBeaconRoot*     : Opt[Hash32]
    slotNumber*            : Opt[uint64]
    parentExcessBlobGas*   : Opt[uint64]
    parentBlobGasUsed*     : Opt[uint64]

  Txo* = object
    chainId* : Opt[UInt256]
    nonce*   : Opt[AccountNonce]
    to*      : string
    gasPrice*: Opt[GasInt]

    gasLimit*: seq[GasInt]
    value*   : seq[UInt256]
    data*    : seq[seq[byte]]

    maxFeePerGas*        : Opt[GasInt]
    accessLists*         : Opt[seq[AccessList]]
    maxPriorityFeePerGas*: Opt[GasInt]
    maxFeePerBlobGas*    : Opt[UInt256]
    blobVersionedHashes* : Opt[seq[Hash32]]
    authorizationList*   : Opt[seq[Authorization]]
    secretKey*           : Opt[PrivateKey]

  TxoReceipt* = object
    transactionHash*  : Hash32
    `type`*           : uint8
    cumulativeGasUsed*: GasInt
    bloom*            : BloomFilter
    logs*             : seq[Log]
    status*           : Opt[bool]
    postState*        : Opt[Hash32]
    rlp*              : seq[byte]

  Index* = object
    data* : int
    gas*  : int
    value*: int

  SubTest* = ref object
    hash*   : Hash32
    logs*   : Hash32
    txbytes*: seq[byte]
    indexes*: Index
    state*  : JsonNode
    receipt*: Opt[TxoReceipt]

  SubTests* = ref object
    subs*: seq[SubTest]

  StateUnit* = ref object
    name*: string
    env* : StateEnv
    pre* : GenesisAlloc
    txo* : Txo
    post*: Table[string, SubTests]

  StateFixture* = ref object
    units*: seq[StateUnit]

Fixture.automaticSerialization(int, true)

StateEnv.useDefaultReaderIn Fixture
Txo.useDefaultReaderIn Fixture
TxoReceipt.useDefaultReaderIn Fixture
SubTest.useDefaultReaderIn Fixture
Index.useDefaultReaderIn Fixture

proc readValue*(r: var JsonReader[Fixture], val: var PrivateKey)
       {.raises: [IOError, JsonReaderError].} =
  var secretKey = r.parseString()
  removePrefix(secretKey, "0x")
  val = PrivateKey.fromHex(secretKey).valueOr:
    r.raiseUnexpectedValue($error)

proc readValue(r: var JsonReader[Fixture], val: SubTests)
       {.raises: [IOError, SerializationError].} =
  r.parseArray:
    val.subs.add r.readValue(SubTest)

proc parsePost(r: var JsonReader[Fixture], unit: StateUnit)
       {.raises: [IOError, SerializationError].} =
  r.parseObject(key):
    let val = SubTests()
    r.readValue(val)
    unit.post[key] = val

proc readValue(r: var JsonReader[Fixture], val: StateUnit)
       {.raises: [IOError, SerializationError].} =
  r.parseObject(key):
    case key
    of "env": r.readValue(val.env)
    of "pre": r.readValue(val.pre)
    of "transaction": r.readValue(val.txo)
    of "post": r.parsePost(val)
    else: discard r.readValue(JsonString)

proc readValue*(r: var JsonReader[Fixture], val: var StateFixture)
       {.raises: [IOError, SerializationError].} =
  val = StateFixture()
  r.parseObjectCustomKey:
    let unit = StateUnit(
      name: r.parseString()
    )
  do:
    r.readValue(unit)
    val.units.add unit
