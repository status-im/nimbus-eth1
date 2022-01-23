# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
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

import
  std/[options, strutils],
  ../utils,
  ./pow/[pow_cache, pow_dataset],
  bearssl,
  eth/[common, keys, p2p, rlp],
  ethash,
  nimcrypto,
  stint

{.push raises: [Defect].}

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
    fullByEpoch: PowDatasetRef    ## Ditto for dataset
    nonceAttempts: uint64         ## Unsuccessful tests in last mining process

    # You should only create one instance of the RNG per application / library
    # Ref is used so that it can be shared between components
    rng: ref BrHmacDrbgContext

# ------------------------------------------------------------------------------
# Private functions: RLP support
# ------------------------------------------------------------------------------

proc append(w: var RlpWriter; specs: PowSpecs) =
  ## RLP support
  w.startList(5)
  w.append(HashOrNum(isHash: false, number: specs.blockNumber))
  w.append(HashOrNum(isHash: true, hash: specs.miningHash))
  w.append(specs.nonce.toUint)
  w.append(HashOrNum(isHash: true, hash: specs.mixDigest))
  w.append(specs.difficulty)

proc read(rlp: var Rlp; Q: type PowSpecs): Q
    {.raises: [Defect,RlpError].} =
  ## RLP support
  rlp.tryEnterList()
  result.blockNumber = rlp.read(HashOrNum).number
  result.miningHash =  rlp.read(HashOrNum).hash
  result.nonce =       rlp.read(uint64).toBlockNonce
  result.mixDigest =   rlp.read(HashOrNum).hash
  result.difficulty =  rlp.read(DifficultyInt)

proc rlpTextEncode(specs: PowSpecs): string =
  "specs #" & $specs.blockNumber & " " & rlp.encode(specs).toHex

proc decodeRlpText(data: string): PowSpecs
    {.raises: [Defect,CatchableError].} =
  if 180 < data.len and data[0 .. 6] == "specs #":
    let hexData = data.split
    if hexData.len == 3:
      var rlpData = hexData[2].rlpFromHex
      result = rlpData.read(PowSpecs)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc miningHash(header: BlockHeader): Hash256 =
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

proc tryNonceFull(nonce: uint64;
                  ds: PowDatasetItemRef; hash: Hash256): Uint256 =
  let
    rc = hashimotoFull(ds.size, ds.data, hash, nonce)
    value = readUintBE[256](rc.value.data)

  # echo ">>> nonce=", nonce.toHex, " value=", value.toHex
  return value

proc mineFull(tm: PowRef; blockNumber: BlockNumber; powHeaderDigest: Hash256,
                difficulty: DifficultyInt; startNonce: BlockNonce): uint64
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Returns a valid nonce. This function was inspired by the function
  ## python function `mine()` from
  ## `ethash <https://eth.wiki/en/concepts/ethash/ethash>`_.
  result = startNonce.toUint

  if difficulty.isZero:
    # Ooops???
    return

  let
    ds = tm.fullByEpoch.get(blockNumber)
    valueMax = Uint256.high div difficulty

  while valueMax < result.tryNonceFull(ds, powHeaderDigest):
    result.inc # rely on uint overflow mod 2^64

  # Book keeping, debugging support
  tm.nonceAttempts = if result <= startNonce.toUint:
                       startNonce.toUint - result
                     else:
                       (uint64.high - startNonce.toUint) + result

# ---------------

proc init(tm: PowRef;
          rng: Option[ref BrHmacDrbgContext];
          light: Option[PowCacheRef];
          full: Option[PowDatasetRef]) =
  ## Constructor
  if rng.isSome:
    tm.rng = rng.get
  else:
    tm.rng = newRng()

  if light.isSome:
    tm.lightByEpoch = light.get
  else:
    tm.lightByEpoch = PowCacheRef.new

  if full.isSome:
    tm.fullByEpoch = full.get
  else:
    tm.fullByEpoch = PowDatasetRef.new(cache = tm.lightByEpoch)

# ------------------------------------------------------------------------------
# Public functions, Constructor
# ------------------------------------------------------------------------------

proc new*(T: type PowRef;
          rng: ref BrHmacDrbgContext;
          cache: PowCacheRef;
          dataset: PowDatasetRef): T =
  ## Constructor
  new result
  result.init(
    some(rng), some(cache), some(dataset))

proc new*(T: type PowRef; cache: PowCacheRef; dataset: PowDatasetRef): T =
  ## Constructor
  new result
  result.init(
    none(ref BrHmacDrbgContext), some(cache), some(dataset))

proc new*(T: type PowRef; rng: ref BrHmacDrbgContext): T =
  ## Constructor
  new result
  result.init(
    some(rng), none(PowCacheRef), none(PowDatasetRef))

proc new*(T: type PowRef): T =
  ## Constructor
  new result
  result.init(
    none(ref BrHmacDrbgContext), none(PowCacheRef), none(PowDatasetRef))

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getPowSpecs*(header: BlockHeader): PowSpecs =
  ## Extracts relevant parts from the `header` argument that are needed
  ## for mining or pow verification. This function might be more useful for
  ## testing and debugging than for production.
  PowSpecs(
    blockNumber: header.blockNumber,
    miningHash:  header.miningHash,
    nonce:       header.nonce,
    mixDigest:   header.mixDigest,
    difficulty:  header.difficulty)

proc getPowCacheLookup*(tm: PowRef;
                        blockNumber: BlockNumber): (uint64, Hash256)
    {.gcsafe, raises: [KeyError, Defect, CatchableError].} =
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

  var ctx: keccak256
  ctx.init()

  for a in ds.data:
    ctx.update(a.data[0].unsafeAddr, uint(a.data.len))

  ctx.finish result[1].data
  ctx.clear()

# ------------------------

proc getPowDigest*(tm: PowRef; blockNumber: BlockNumber;
                   powHeaderDigest: Hash256; nonce: BlockNonce): PowDigest
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Calculate the expected value of `header.mixDigest` using the
  ## `hashimotoLight()` library method.
  let
    ds = tm.lightByEpoch.get(blockNumber)
    u64Nonce = uint64.fromBytesBE(nonce)
  hashimotoLight(ds.size, ds.data, powHeaderDigest, u64Nonce)

proc getPowDigest*(tm: PowRef; header: BlockHeader): PowDigest
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Variant of `getPowDigest()`
  tm.getPowDigest(header.blockNumber, header.miningHash, header.nonce)

proc getPowDigest*(tm: PowRef; specs: PowSpecs): PowDigest
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Variant of `getPowDigest()`
  tm.getPowDigest(specs.blockNumber, specs.miningHash, specs.nonce)

# ------------------

proc getNonce*(tm: PowRef; number: BlockNumber; powHeaderDigest: Hash256;
               difficulty: DifficultyInt; startNonce: BlockNonce): BlockNonce
      {.gcsafe,raises: [Defect,CatchableError].} =
  ## Mining function that calculates the value of a `nonce` satisfying the
  ## difficulty challenge. This is the most basic function of the
  ## `getNonce()` series with explicit argument `startNonce`. If this is
  ## a valid `nonce` already, the function stops and returns that value.
  ## Otherwise it derives other nonces from the `startNonce` start and
  ## continues trying.
  ##
  ## The function depends on a mining dataset which can be generated with
  ## `generatePowDataset()` before that function is invoked.
  ##
  ## This mining logic was inspired by the Python function `mine()` from
  ## `ethash <https://eth.wiki/en/concepts/ethash/ethash>`_.
  tm.mineFull(number, powHeaderDigest, difficulty, startNonce).toBytesBE

proc getNonce*(tm: PowRef; number: BlockNumber; powHeaderDigest: Hash256;
                  difficulty: DifficultyInt): BlockNonce
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Variant of `getNonce()`
  var startNonce: array[8,byte]
  tm.rng[].brHmacDrbgGenerate(startNonce)
  tm.getNonce(number, powHeaderDigest, difficulty, startNonce)

proc getNonce*(tm: PowRef; header: BlockHeader): BlockNonce
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Variant of `getNonce()`
  tm.getNonce(header.blockNumber, header.miningHash, header.difficulty)

proc getNonce*(tm: PowRef; specs: PowSpecs): BlockNonce
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Variant of `getNonce()`
  tm.getNonce(specs.blockNumber, specs.miningHash, specs.difficulty)

proc nGetNonce*(tm: PowRef): uint64 =
  ## Number of unsucchessful internal tests in the last invocation
  ## of `getNonce()`.
  tm.nonceAttempts

# ------------------

proc generatePowDataset*(tm: PowRef; number: BlockNumber)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Prepare dataset for the `getNonce()` mining function. This dataset
  ## changes with the epoch of the argument `number` so it is applicable for
  ## the full epoch. If not generated explicitely, it will be done so by the
  ## next invocation of `getNonce()`.
  ##
  ## This is a slow process which produces a huge data table. So expect this
  ## function to hang on for a while and do not mind if the OS starts swapping.
  ## A list of the data sizes indexed by epoch is available at the end of
  ## the `ethash <https://eth.wiki/en/concepts/ethash/ethash>`_ Python
  ## reference implementation.
  discard tm.fullByEpoch.get(number)

# ------------------------------------------------------------------------------
# Public functions, debugging & testing
# ------------------------------------------------------------------------------

proc dumpPowSpecs*(specs: PowSpecs): string =
  ## Text representation of `PowSpecs` argument object
  specs.rlpTextEncode

proc dumpPowSpecs*(header: BlockHeader): string =
  ## Variant of `dumpPowSpecs()`
  header.getPowSpecs.dumpPowSpecs

proc undumpPowSpecs*(data: string): PowSpecs
    {.raises: [Defect,CatchableError].} =
  ## Recover `PowSpecs` object from text representation
  data.decodeRlpText

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
