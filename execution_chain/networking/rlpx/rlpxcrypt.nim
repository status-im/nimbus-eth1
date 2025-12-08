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
  nimcrypto/[bcmode, rijndael, utils], results,
  eth/keccak/keccak
from auth import ConnectionSecret

export results

const
  RlpHeaderLength* = 16
  RlpMacLength* = 16
  maxUInt24 = (not uint32(0)) shl 8

type
  Keccak256 = keccak.Keccak256

  SecretState* = object
    ## Object represents current encryption/decryption context.
    aesenc*: CTR[aes256]
    aesdec*: CTR[aes256]
    macenc*: ECB[aes256]
    emac*: Keccak256
    imac*: Keccak256

  RlpxError* = enum
    IncorrectMac = "rlpx: MAC verification failed"
    BufferOverrun = "rlpx: buffer overrun"
    IncompleteError = "rlpx: data incomplete"
    IncorrectArgs = "rlpx: incorrect arguments"

  RlpxEncryptedHeader* = array[RlpHeaderLength + RlpMacLength, byte]
  RlpxHeader* = array[RlpHeaderLength, byte]

  RlpxResult*[T] = Result[T, RlpxError]

proc roundup16*(x: int): int {.inline.} =
  ## Procedure aligns `x` to
  let rem = x and 15
  if rem != 0:
    result = x + 16 - rem
  else:
    result = x

template toa(a, b, c: untyped): untyped =
  toOpenArray((a), (b), (b) + (c) - 1)

proc sxor[T](a: var openArray[T], b: openArray[T]) {.inline.} =
  doAssert(len(a) == len(b))
  for i in 0 ..< len(a):
    a[i] = a[i] xor b[i]

proc initSecretState*(secrets: ConnectionSecret, context: var SecretState) =
  ## Initialized `context` with values from `secrets`.

  # This scheme is insecure, see:
  # https://github.com/ethereum/devp2p/issues/32
  # https://github.com/ethereum/py-evm/blob/master/p2p/peer.py#L159-L160
  var iv: array[context.aesenc.sizeBlock, byte]
  context.aesenc.init(secrets.aesKey, iv)
  context.aesdec = context.aesenc
  context.macenc.init(secrets.macKey)
  context.emac = secrets.egressMac
  context.imac = secrets.ingressMac

template encryptedLength*(size: int): int =
  ## Returns the number of bytes used by the entire frame of a
  ## message with size `size`:
  RlpHeaderLength + roundup16(size) + 2 * RlpMacLength

template decryptedLength*(size: int): int =
  ## Returns size of decrypted message for body with length `size`.
  roundup16(size)

proc encrypt*(c: var SecretState, header: openArray[byte],
              frame: openArray[byte],
              output: var openArray[byte]): RlpxResult[void] =
  ## Encrypts `header` and `frame` using SecretState `c` context and store
  ## result into `output`.
  ##
  ## `header` must be exactly `RlpHeaderLength` length.
  ## `frame` must not be zero length.
  ## `output` must be at least `encryptedLength(len(frame))` length.
  var
    tmpmac: Keccak256
    aes: array[RlpHeaderLength, byte]
  let length = encryptedLength(len(frame))
  let frameLength = roundup16(len(frame))
  let headerMacPos = RlpHeaderLength
  let framePos = RlpHeaderLength + RlpMacLength
  let frameMacPos = RlpHeaderLength * 2 + frameLength
  if len(header) != RlpHeaderLength or len(frame) == 0 or length != len(output):
    return err(IncorrectArgs)
  # header_ciphertext = self.aes_enc.update(header)
  c.aesenc.encrypt(header, toa(output, 0, RlpHeaderLength))
  # mac_secret = self.egress_mac.digest()[:HEADER_LEN]
  tmpmac = c.emac
  var macsec = tmpmac.finish()
  # self.egress_mac.update(sxor(self.mac_enc(mac_secret), header_ciphertext))
  c.macenc.encrypt(toa(macsec.data, 0, RlpHeaderLength), aes)
  sxor(aes, toa(output, 0, RlpHeaderLength))
  c.emac.update(aes)
  burnMem(aes)
  # header_mac = self.egress_mac.digest()[:HEADER_LEN]
  tmpmac = c.emac
  var headerMac = tmpmac.finish()
  # frame_ciphertext = self.aes_enc.update(frame)
  copyMem(addr output[framePos], unsafeAddr frame[0], len(frame))
  c.aesenc.encrypt(toa(output, 32, frameLength), toa(output, 32, frameLength))
  # self.egress_mac.update(frame_ciphertext)
  c.emac.update(toa(output, 32, frameLength))
  # fmac_seed = self.egress_mac.digest()[:HEADER_LEN]
  tmpmac = c.emac
  var seed = tmpmac.finish()
  # mac_secret = self.egress_mac.digest()[:HEADER_LEN]
  macsec = seed
  # self.egress_mac.update(sxor(self.mac_enc(mac_secret), fmac_seed))
  c.macenc.encrypt(toa(macsec.data, 0, RlpHeaderLength), aes)
  sxor(aes, toa(seed.data, 0, RlpHeaderLength))
  c.emac.update(aes)
  burnMem(aes)
  # frame_mac = self.egress_mac.digest()[:HEADER_LEN]
  tmpmac = c.emac
  var frameMac = tmpmac.finish()
  tmpmac.clear()
  # return header_ciphertext + header_mac + frame_ciphertext + frame_mac
  copyMem(addr output[headerMacPos], addr headerMac.data[0], RlpMacLength)
  copyMem(addr output[frameMacPos], addr frameMac.data[0], RlpMacLength)
  ok()

proc encryptMsg*(msg: openArray[byte], secrets: var SecretState): seq[byte] =
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

proc getBodySize*(a: RlpxHeader): int =
  (int(a[0]) shl 16) or (int(a[1]) shl 8) or int(a[2])

proc decryptHeader*(c: var SecretState, data: openArray[byte]): RlpxResult[RlpxHeader] =
  ## Decrypts header `data` using SecretState `c` context and store
  ## result into `output`.
  ##
  ## `header` must be at least `RlpHeaderLength + RlpMacLength` length.

  var
    tmpmac: Keccak256
    aes: array[RlpHeaderLength, byte]

  if len(data) < RlpHeaderLength + RlpMacLength:
    return err(IncompleteError)

  # mac_secret = self.ingress_mac.digest()[:HEADER_LEN]
  tmpmac = c.imac
  var macsec = tmpmac.finish()
  # aes = self.mac_enc(mac_secret)[:HEADER_LEN]
  c.macenc.encrypt(toa(macsec.data, 0, RlpHeaderLength), aes)
  # self.ingress_mac.update(sxor(aes, header_ciphertext))
  sxor(aes, toa(data, 0, RlpHeaderLength))
  c.imac.update(aes)
  burnMem(aes)
  # expected_header_mac = self.ingress_mac.digest()[:HEADER_LEN]
  tmpmac = c.imac
  var expectMac = tmpmac.finish()
  # if not bytes_eq(expected_header_mac, header_mac):
  if not equalMem(unsafeAddr data[RlpHeaderLength],
                  addr expectMac.data[0], RlpMacLength):
    return err(IncorrectMac)

  # return self.aes_dec.update(header_ciphertext)
  var output: RlpxHeader
  c.aesdec.decrypt(toa(data, 0, RlpHeaderLength), output)
  ok(output)

proc decryptBody*(c: var SecretState, data: openArray[byte], bodysize: int,
                  output: var openArray[byte]): RlpxResult[void] =
  ## Decrypts body `data` using SecretState `c` context and store
  ## result into `output`.
  ##
  ## `data` must be at least `roundup16(bodysize) + RlpMacLength` length.
  ## `output` must be at least `roundup16(bodysize)` length.
  ##
  ## On success completion `outlen` will hold actual size of decrypted body.
  var
    tmpmac: Keccak256
    aes: array[RlpHeaderLength, byte]
  let rsize = roundup16(bodysize)
  if len(data) < rsize + RlpMacLength:
    return err(IncompleteError)
  if len(output) < rsize:
    return err(IncorrectArgs)
  # self.ingress_mac.update(frame_ciphertext)
  c.imac.update(toa(data, 0, rsize))
  tmpmac = c.imac
  # fmac_seed = self.ingress_mac.digest()[:MAC_LEN]
  var seed = tmpmac.finish()
  # self.ingress_mac.update(sxor(self.mac_enc(fmac_seed), fmac_seed))
  c.macenc.encrypt(toa(seed.data, 0, RlpHeaderLength), aes)
  sxor(aes, toa(seed.data, 0, RlpHeaderLength))
  c.imac.update(aes)
  # expected_frame_mac = self.ingress_mac.digest()[:MAC_LEN]
  tmpmac = c.imac
  var expectMac = tmpmac.finish()
  let bodyMacPos = rsize
  if not equalMem(cast[pointer](unsafeAddr data[bodyMacPos]),
                  cast[pointer](addr expectMac.data[0]), RlpMacLength):
    err(IncorrectMac)
  else:
    c.aesdec.decrypt(toa(data, 0, rsize), output)
    ok()
