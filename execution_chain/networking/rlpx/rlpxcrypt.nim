# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## This module implements RLPx cryptography

{.push raises: [].}

import
  nimcrypto/[bcmode, keccak, rijndael, utils], results
from auth import ConnectionSecret

export results

const
  RlpxHeaderLength = 16
  RlpxMacLength = 16
  maxUInt24 = (not uint32(0)) shl 8

type
  RlpxCrypt* = object
    ## Object represents current encryption/decryption context.
    aesenc: CTR[aes256]
    aesdec: CTR[aes256]
    macenc: ECB[aes256]
    emac: keccak256
    imac: keccak256

  RlpxCryptError* = enum
    IncorrectMac = "rlpx: MAC verification failed"
    BufferOverrun = "rlpx: buffer overrun"
    IncompleteError = "rlpx: data incomplete"
    IncorrectArgs = "rlpx: incorrect arguments"

  RlpxEncryptedHeader* = array[RlpxHeaderLength + RlpxMacLength, byte]
  RlpxHeader* = array[RlpxHeaderLength, byte]

  RlpxCryptResult*[T] = Result[T, RlpxCryptError]

func roundup16(x: int): int {.inline.} =
  ## Procedure aligns `x` to
  let rem = x and 15
  if rem != 0:
    result = x + 16 - rem
  else:
    result = x

template toa(a, b, c: untyped): untyped =
  toOpenArray((a), (b), (b) + (c) - 1)

func sxor[T](a: var openArray[T], b: openArray[T]) {.inline.} =
  doAssert(len(a) == len(b))
  for i in 0 ..< len(a):
    a[i] = a[i] xor b[i]

func initRlpxCrypt*(secrets: ConnectionSecret, ctx: var RlpxCrypt) =
  ## Initialized `ctx` with values from `secrets`.

  # This scheme is insecure, see:
  # https://github.com/ethereum/devp2p/issues/32
  # https://github.com/ethereum/py-evm/blob/master/p2p/peer.py#L159-L160
  var iv: array[ctx.aesenc.sizeBlock, byte]
  ctx.aesenc.init(secrets.aesKey, iv)
  ctx.aesdec = ctx.aesenc
  ctx.macenc.init(secrets.macKey)
  ctx.emac = secrets.egressMac
  ctx.imac = secrets.ingressMac

template encryptedLength*(size: int): int =
  ## Returns the number of bytes used by the entire frame of a
  ## message with size `size`:
  RlpxHeaderLength + roundup16(size) + 2 * RlpxMacLength

template decryptedLength*(size: int): int =
  ## Returns size of decrypted message for body with length `size`.
  roundup16(size)

func encrypt(ctx: var RlpxCrypt, header: openArray[byte],
              frame: openArray[byte],
              output: var openArray[byte]): RlpxCryptResult[void] =
  ## Encrypts `header` and `frame` using RlpxCrypt `ctx` context and store
  ## result into `output`.
  ##
  ## `header` must be exactly `RlpxHeaderLength` length.
  ## `frame` must not be zero length.
  ## `output` must be at least `encryptedLength(len(frame))` length.
  var
    tmpmac: keccak256
    aes: array[RlpxHeaderLength, byte]
  let length = encryptedLength(len(frame))
  let frameLength = roundup16(len(frame))
  let headerMacPos = RlpxHeaderLength
  let framePos = RlpxHeaderLength + RlpxMacLength
  let frameMacPos = RlpxHeaderLength * 2 + frameLength
  if len(header) != RlpxHeaderLength or len(frame) == 0 or length != len(output):
    return err(IncorrectArgs)
  # header_ciphertext = self.aes_enc.update(header)
  ctx.aesenc.encrypt(header, toa(output, 0, RlpxHeaderLength))
  # mac_secret = self.egress_mac.digest()[:HEADER_LEN]
  tmpmac = ctx.emac
  var macsec = tmpmac.finish()
  # self.egress_mac.update(sxor(self.mac_enc(mac_secret), header_ciphertext))
  ctx.macenc.encrypt(toa(macsec.data, 0, RlpxHeaderLength), aes)
  sxor(aes, toa(output, 0, RlpxHeaderLength))
  ctx.emac.update(aes)
  burnMem(aes)
  # header_mac = self.egress_mac.digest()[:HEADER_LEN]
  tmpmac = ctx.emac
  var headerMac = tmpmac.finish()
  # frame_ciphertext = self.aes_enc.update(frame)
  copyMem(addr output[framePos], unsafeAddr frame[0], len(frame))
  ctx.aesenc.encrypt(toa(output, 32, frameLength), toa(output, 32, frameLength))
  # self.egress_mac.update(frame_ciphertext)
  ctx.emac.update(toa(output, 32, frameLength))
  # fmac_seed = self.egress_mac.digest()[:HEADER_LEN]
  tmpmac = ctx.emac
  var seed = tmpmac.finish()
  # mac_secret = self.egress_mac.digest()[:HEADER_LEN]
  macsec = seed
  # self.egress_mac.update(sxor(self.mac_enc(mac_secret), fmac_seed))
  ctx.macenc.encrypt(toa(macsec.data, 0, RlpxHeaderLength), aes)
  sxor(aes, toa(seed.data, 0, RlpxHeaderLength))
  ctx.emac.update(aes)
  burnMem(aes)
  # frame_mac = self.egress_mac.digest()[:HEADER_LEN]
  tmpmac = ctx.emac
  var frameMac = tmpmac.finish()
  tmpmac.clear()
  # return header_ciphertext + header_mac + frame_ciphertext + frame_mac
  copyMem(addr output[headerMacPos], addr headerMac.data[0], RlpxMacLength)
  copyMem(addr output[frameMacPos], addr frameMac.data[0], RlpxMacLength)
  ok()

func encryptMsg*(msg: openArray[byte], secrets: var RlpxCrypt): seq[byte] =
  doAssert(uint32(msg.len) <= maxUInt24, "RLPx message size exceeds limit")

  var header: RlpxHeader
  # write the frame size in the first 3 bytes of the header
  header[0] = byte((msg.len shr 16) and 0xFF)
  header[1] = byte((msg.len shr 8) and 0xFF)
  header[2] = byte(msg.len and 0xFF)
  # This is the  [capability-id, context-id] in header-data
  # While not really used, this is checked in the Parity client.
  # Same as rlp.encode((0, 0))
  header[3] = 0xc2
  header[4] = 0x80
  header[5] = 0x80

  var res = newSeq[byte](encryptedLength(msg.len))
  encrypt(secrets, header, msg, res).expect(
    "always succeeds because we call with correct buffer")
  res

func getBodySize*(a: RlpxHeader): int =
  (int(a[0]) shl 16) or (int(a[1]) shl 8) or int(a[2])

func decryptHeader*(ctx: var RlpxCrypt, data: openArray[byte]): RlpxCryptResult[RlpxHeader] =
  ## Decrypts header `data` using RlpxCrypt `ctx` context and store
  ## result into `output`.
  ##
  ## `header` must be at least `RlpxHeaderLength + RlpxMacLength` length.

  var
    tmpmac: keccak256
    aes: array[RlpxHeaderLength, byte]

  if len(data) < RlpxHeaderLength + RlpxMacLength:
    return err(IncompleteError)

  # mac_secret = self.ingress_mac.digest()[:HEADER_LEN]
  tmpmac = ctx.imac
  var macsec = tmpmac.finish()
  # aes = self.mac_enc(mac_secret)[:HEADER_LEN]
  ctx.macenc.encrypt(toa(macsec.data, 0, RlpxHeaderLength), aes)
  # self.ingress_mac.update(sxor(aes, header_ciphertext))
  sxor(aes, toa(data, 0, RlpxHeaderLength))
  ctx.imac.update(aes)
  burnMem(aes)
  # expected_header_mac = self.ingress_mac.digest()[:HEADER_LEN]
  tmpmac = ctx.imac
  var expectMac = tmpmac.finish()
  # if not bytes_eq(expected_header_mac, header_mac):
  if not equalMem(unsafeAddr data[RlpxHeaderLength],
                  addr expectMac.data[0], RlpxMacLength):
    return err(IncorrectMac)

  # return self.aes_dec.update(header_ciphertext)
  var output: RlpxHeader
  ctx.aesdec.decrypt(toa(data, 0, RlpxHeaderLength), output)
  ok(output)

func decryptBody*(ctx: var RlpxCrypt, data: openArray[byte], bodysize: int,
                  output: var openArray[byte]): RlpxCryptResult[void] =
  ## Decrypts body `data` using RlpxCrypt `ctx` context and store
  ## result into `output`.
  ##
  ## `data` must be at least `roundup16(bodysize) + RlpxMacLength` length.
  ## `output` must be at least `roundup16(bodysize)` length.
  ##
  ## On success completion `outlen` will hold actual size of decrypted body.
  var
    tmpmac: keccak256
    aes: array[RlpxHeaderLength, byte]
  let rsize = roundup16(bodysize)
  if len(data) < rsize + RlpxMacLength:
    return err(IncompleteError)
  if len(output) < rsize:
    return err(IncorrectArgs)
  # self.ingress_mac.update(frame_ciphertext)
  ctx.imac.update(toa(data, 0, rsize))
  tmpmac = ctx.imac
  # fmac_seed = self.ingress_mac.digest()[:MAC_LEN]
  var seed = tmpmac.finish()
  # self.ingress_mac.update(sxor(self.mac_enc(fmac_seed), fmac_seed))
  ctx.macenc.encrypt(toa(seed.data, 0, RlpxHeaderLength), aes)
  sxor(aes, toa(seed.data, 0, RlpxHeaderLength))
  ctx.imac.update(aes)
  # expected_frame_mac = self.ingress_mac.digest()[:MAC_LEN]
  tmpmac = ctx.imac
  var expectMac = tmpmac.finish()
  let bodyMacPos = rsize
  if not equalMem(cast[pointer](unsafeAddr data[bodyMacPos]),
                  cast[pointer](addr expectMac.data[0]), RlpxMacLength):
    err(IncorrectMac)
  else:
    ctx.aesdec.decrypt(toa(data, 0, rsize), output)
    ok()
