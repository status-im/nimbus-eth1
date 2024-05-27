# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Block PoW Support (Verifying & Mining)
## ======================================
##

{.push raises: [].}

import
  std/[options, strutils],
  ../utils/utils,
  ./pow/pow_cache,
  eth/[common, keys, p2p, rlp],
  stew/endians2,
  ethash,
  stint

type
  PowDigest = tuple ##\
    ## Return value from the `hashimotoLight()` function
    mixDigest: Hash256
    value: Hash256

  PowSpecs* = object ##\
    ## Relevant block header parts for PoW mining & verifying. This object
    ## might be more useful for testing and debugging than for production.
    blockNumber*: BlockNumber
    miningHash*: Hash256
    nonce*: BlockNonce
    mixDigest*: Hash256
    difficulty*: DifficultyInt

  PowHeader = object ##\
    ## Stolen from `p2p/validate.MiningHeader`
    parentHash  : Hash256
    ommersHash  : Hash256
    coinbase    : EthAddress
    stateRoot   : Hash256
    txRoot      : Hash256
    receiptRoot : Hash256
    bloom       : common.BloomFilter
    difficulty  : DifficultyInt
    blockNumber : BlockNumber
    gasLimit    : GasInt
    gasUsed     : GasInt
    timestamp   : EthTime
    extraData   : Blob

  PowRef* = ref object of RootObj ##\
    ## PoW context descriptor
    lightByEpoch: PowCacheRef     ## PoW cache indexed by epoch
    nonceAttempts: uint64         ## Unsuccessful tests in last mining process

    # You should only create one instance of the RNG per application / library
    # Ref is used so that it can be shared between components
    rng: ref HmacDrbgContext

# ------------------------------------------------------------------------------
# Private functions: RLP support
# ------------------------------------------------------------------------------

func append(w: var RlpWriter; specs: PowSpecs) =
  ## RLP support
  w.startList(5)
  w.append(HashOrNum(isHash: false, number: specs.blockNumber))
  w.append(HashOrNum(isHash: true, hash: specs.miningHash))
  w.append(specs.nonce.toUint)
  w.append(HashOrNum(isHash: true, hash: specs.mixDigest))
  w.append(specs.difficulty)

func read(rlp: var Rlp; Q: type PowSpecs): Q
    {.raises: [RlpError].} =
  ## RLP support
  rlp.tryEnterList()
  result.blockNumber = rlp.read(HashOrNum).number
  result.miningHash =  rlp.read(HashOrNum).hash
  result.nonce =       rlp.read(uint64).toBlockNonce
  result.mixDigest =   rlp.read(HashOrNum).hash
  result.difficulty =  rlp.read(DifficultyInt)

func rlpTextEncode(specs: PowSpecs): string =
  "specs #" & $specs.blockNumber & " " & rlp.encode(specs).toHex

func decodeRlpText(data: string): PowSpecs
    {.raises: [CatchableError].} =
  if 180 < data.len and data[0 .. 6] == "specs #":
    let hexData = data.split
    if hexData.len == 3:
      var rlpData = hexData[2].rlpFromHex
      result = rlpData.read(PowSpecs)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func miningHash(header: BlockHeader): Hash256 =
  ## Calculate hash from mining relevant fields of the argument `header`
  let miningHeader = PowHeader(
    parentHash:  header.parentHash,
    ommersHash:  header.ommersHash,
    coinbase:    header.coinbase,
    stateRoot:   header.stateRoot,
    txRoot:      header.txRoot,
    receiptRoot: header.receiptRoot,
    bloom:       header.bloom,
    difficulty:  header.difficulty,
    blockNumber: header.blockNumber,
    gasLimit:    header.gasLimit,
    gasUsed:     header.gasUsed,
    timestamp:   header.timestamp,
    extraData:   header.extraData)

  rlp.encode(miningHeader).keccakHash

# ---------------

proc init(tm: PowRef;
          rng: Option[ref HmacDrbgContext];
          light: Option[PowCacheRef]) =
  ## Constructor
  if rng.isSome:
    tm.rng = rng.get
  else:
    tm.rng = newRng()

  if light.isSome:
    tm.lightByEpoch = light.get
  else:
    tm.lightByEpoch = PowCacheRef.new

# ------------------------------------------------------------------------------
# Public functions, Constructor
# ------------------------------------------------------------------------------

proc new*(T: type PowRef; cache: PowCacheRef): T =
  ## Constructor
  new result
  result.init(none(ref HmacDrbgContext), some(cache))

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func getPowSpecs*(header: BlockHeader): PowSpecs =
  ## Extracts relevant parts from the `header` argument that are needed
  ## for mining or pow verification. This function might be more useful for
  ## testing and debugging than for production.
  PowSpecs(
    blockNumber: header.blockNumber,
    miningHash:  header.miningHash,
    nonce:       header.nonce,
    mixDigest:   header.mixDigest,
    difficulty:  header.difficulty)

func getPowCacheLookup*(tm: PowRef;
                        blockNumber: BlockNumber): (uint64, Hash256)
    {.gcsafe, raises: [KeyError].} =
  ## Returns the pair `(size,digest)` derived from the lookup cache for the
  ## `hashimotoLight()` function for the given block number. The `size` is the
  ## full size of the dataset (the cache represents) as passed on to the
  ## `hashimotoLight()` function. The `digest` is a hash derived from the
  ## cache that would be passed on to `hashimotoLight()`.
  ##
  ## This function is intended for error reporting and might also be useful
  ## for testing and debugging.
  let ds = tm.lightByEpoch.get(blockNumber)
  if ds == nil:
    raise newException(KeyError, "block not found")

  result[0] = ds.size
  result[1] = withKeccakHash:
    for a in ds.data:
      h.update(a.data)

# ------------------------

func getPowDigest(tm: PowRef; blockNumber: BlockNumber;
                  powHeaderDigest: Hash256; nonce: BlockNonce): PowDigest =
  ## Calculate the expected value of `header.mixDigest` using the
  ## `hashimotoLight()` library method.
  let
    ds = tm.lightByEpoch.get(blockNumber)
    u64Nonce = uint64.fromBytesBE(nonce)
  hashimotoLight(ds.size, ds.data, powHeaderDigest, u64Nonce)

func getPowDigest*(tm: PowRef; header: BlockHeader): PowDigest =
  ## Variant of `getPowDigest()`
  tm.getPowDigest(header.blockNumber, header.miningHash, header.nonce)

func getPowDigest*(tm: PowRef; specs: PowSpecs): PowDigest =
  ## Variant of `getPowDigest()`
  tm.getPowDigest(specs.blockNumber, specs.miningHash, specs.nonce)

# ------------------------------------------------------------------------------
# Public functions, debugging & testing
# ------------------------------------------------------------------------------

func dumpPowSpecs*(specs: PowSpecs): string =
  ## Text representation of `PowSpecs` argument object
  specs.rlpTextEncode

func dumpPowSpecs*(header: BlockHeader): string =
  ## Variant of `dumpPowSpecs()`
  header.getPowSpecs.dumpPowSpecs

func undumpPowSpecs*(data: string): PowSpecs
    {.raises: [CatchableError].} =
  ## Recover `PowSpecs` object from text representation
  data.decodeRlpText

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
