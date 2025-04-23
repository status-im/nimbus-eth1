# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## This module implements ECIES method encryption/decryption.
## https://github.com/ethereum/devp2p/blob/5713591d0366da78a913a811c7502d9ca91d29a8/rlpx.md?plain=1#L31

{.push raises: [].}

import
  stew/[assign2, endians2],
  results,
  nimcrypto/[rijndael, bcmode, hash, hmac, sha2, utils],
  eth/common/keys

export results, keys

const
  ivLen = aes128.sizeBlock
  tagLen = sha256.sizeDigest

  eciesOverheadLength* =
    # Data overhead size for ECIES encrypted message
    # pubkey + IV + MAC = 65 + 16 + 32 = 113
    1 + sizeof(PublicKey) + ivLen + tagLen

type
  EciesError* = enum
    BufferOverrun = "ecies: output buffer size is too small"
    EcdhError = "ecies: ECDH shared secret could not be calculated"
    WrongHeader = "ecies: header is incorrect"
    IncorrectKey = "ecies: recovered public key is invalid"
    IncorrectTag = "ecies: tag verification failed"
    IncompleteError = "ecies: decryption needs more data"

  EciesResult*[T] = Result[T, EciesError]

template eciesEncryptedLength*(size: int): int =
  ## Return size of encrypted message for message with size `size`.
  size + eciesOverheadLength

func eciesDecryptedLength*(size: int): Result[int, EciesError] =
  ## Return size of decrypted message for encrypted message with size `size`.
  if size >= eciesOverheadLength:
    ok size - eciesOverheadLength
  else:
    err IncompleteError

template version(v: openArray[byte]): untyped =
  v[0]

template pubkey(v: openArray[byte]): untyped =
  v.toOpenArray(1, 1 + sizeof(PublicKey) - 1)

template iv(v: openArray[byte]): untyped =
  v.toOpenArray(1 + sizeof(PublicKey), 1 + sizeof(PublicKey) + ivLen - 1)

template data(v: openArray[byte], inputLen): untyped =
  v.toOpenArray(
    1 + sizeof(PublicKey) + ivLen, 1 + sizeof(PublicKey) + ivLen + inputLen - 1
  )

template ivdata(v: openArray[byte], inputLen): untyped =
  v.toOpenArray(1 + sizeof(PublicKey), 1 + sizeof(PublicKey) + ivLen + inputLen - 1)

template tag(v: openArray[byte], inputLen: int): untyped =
  v.toOpenArray(
    1 + sizeof(PublicKey) + ivLen + inputLen,
    1 + sizeof(PublicKey) + ivLen + inputLen + tagLen - 1,
  )

template enckey(material: openArray[byte]): untyped =
  material.toOpenArray(0, aes128.sizeKey - 1)

template mackey(material: openArray[byte]): untyped =
  sha256.digest(material.toOpenArray(aes128.sizeKey, material.len - 1))

func kdf*(data: openArray[byte]): array[KeyLength, byte] {.noinit.} =
  ## NIST SP 800-56a Concatenation Key Derivation Function (see section 5.8.1)
  var
    ctx: sha256
    counter = 1'u32
    offset = 0
    hash: MDigest[256]

  while offset < result.len:
    ctx.init()
    ctx.update(toBytesBE(counter))
    ctx.update(data)
    hash = ctx.finish()
    let bytes = min(hash.data.len, result.len - offset)
    assign(
      result.toOpenArray(offset, offset + bytes - 1),
      hash.data.toOpenArray(0, bytes - 1),
    )

    offset += bytes
    counter += 1

  hash.burnMem()
  ctx.clear() # clean ctx

proc eciesEncrypt*(
    rng: var HmacDrbgContext,
    input: openArray[byte],
    output: var openArray[byte],
    pubkey: PublicKey,
    sharedmac: openArray[byte] = [],
): EciesResult[void] =
  ## Encrypt data with ECIES method using given public key `pubkey`.
  ## ``input``     - input data
  ## ``output``    - output data
  ## ``pubkey``    - ECC public key
  ## ``sharedmac`` - additional data used to calculate encrypted message MAC
  ## Length of output data can be calculated using ``eciesEncryptedLength()``
  ## template.
  if len(output) < eciesEncryptedLength(len(input)):
    return err(BufferOverrun)

  var
    ephemeral = KeyPair.random(rng)
    secret = ecdhSharedSecret(ephemeral.seckey, pubkey)
    material = kdf(secret.data)

  clear(secret)

  output.version() = 0x04

  block: # pubkey
    assign(output.pubkey, ephemeral.pubkey.toRaw())
    ephemeral.clear()

  block: # iv
    rng.generate(output.iv())

  block: # ciphertext
    var cipher: CTR[aes128]
    cipher.init(material.enckey(), output.iv())
    cipher.encrypt(input, output.data(input.len))
    cipher.clear()

  block: # mac
    var mackey = material.mackey()
    burnMem(material)

    var ctx: HMAC[sha256]
    ctx.init(mackey.data)
    mackey.burnMem()

    ctx.update(output.ivdata(input.len))
    ctx.update(sharedmac)

    let tag = ctx.finish()
    assign(output.tag(input.len), tag.data)
    ctx.clear()

  ok()

func eciesDecrypt*(
    input: openArray[byte],
    output: var openArray[byte],
    seckey: PrivateKey,
    sharedmac: openArray[byte] = [],
): EciesResult[void] =
  ## Decrypt data with ECIES method using given private key `seckey`.
  ## ``input``     - input data
  ## ``output``    - output data
  ## ``pubkey``    - ECC private key
  ## ``sharedmac`` - additional data used to calculate encrypted message MAC
  ## Length of output data can be calculated using ``eciesDecryptedLength()``
  ## template.

  let plainLen = ?eciesDecryptedLength(input.len)
  if plainLen > len(output):
    return err(BufferOverrun)

  if input.version() != byte 0x04:
    return err(WrongHeader)

  var
    pubkey = PublicKey.fromRaw(input.pubkey).valueOr:
      return err(IncorrectKey)
    secret = ecdhSharedSecret(seckey, pubkey)
    material = kdf(secret.data)

  secret.clear()

  block: # mac
    var mackey = material.mackey()

    var ctx: HMAC[sha256]
    ctx.init(mackey.data)
    burnMem(mackey)

    ctx.update(input.ivdata(plainLen))
    ctx.update(sharedmac)

    let tag = ctx.finish()
    ctx.clear()

    if tag.data != input.tag(plainLen):
      burnMem(material)
      return err(IncorrectTag)

  block: # ciphertext
    var cipher: CTR[aes128]
    cipher.init(material.enckey(), input.iv())
    burnMem(material)

    cipher.decrypt(input.data(plainLen), output)
    cipher.clear()

  ok()
