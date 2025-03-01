# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/net,
  testutils/fuzzing, chronicles, nimcrypto/keccak,
  eth/[keys, rlp],
  ../../../../execution_chain/networking/discoveryv4,
  ../../p2p_test_helper

const DefaultListeningPort = 30303
var targetNode: DiscoveryProtocol

proc packData(payload: openArray[byte], pk: PrivateKey): seq[byte] =
  let
    payloadSeq = @payload
    signature = @(pk.sign(payload).toRaw())
    msgHash = keccak256.digest(signature & payloadSeq)
  result = @(msgHash.data) & signature & payloadSeq

init:
  # Set up a discovery node, this is the node we target when fuzzing
  var
    targetNodeKey = PrivateKey.fromHex("a2b50376a79b1a8c8a3296485572bdfbf54708bb46d3c25d73d2723aaaf6a617")[]
    targetNodeAddr = localAddress(DefaultListeningPort)
  targetNode = newDiscoveryProtocol(
    targetNodeKey, targetNodeAddr, @[], Port(DefaultListeningPort))
  # Create the transport as else replies on the messages send will fail.
  targetNode.open()

test:
  var
    msg: seq[byte]
    address: Address

  # Sending raw payload is possible but won't find us much. We need a hash and
  # a signature, and without it there is a big chance it will always result in
  # "Wrong msg mac from" error.
  let nodeKey = PrivateKey.fromHex("a2b50376a79b1a8c8a3296485572bdfbf54708bb46d3c25d73d2723aaaf6a618")[]
  msg = packData(payload, nodeKey)
  address = localAddress(DefaultListeningPort + 1)

  try:
    targetNode.receive(address, msg)
  # These errors are also caught in `processClient` in discovery.nim
  # TODO: move them a layer down in discovery so we can do a cleaner test there?
  except RlpError as e:
    debug "Receive failed", err = e.msg
  except DiscProtocolError as e:
    debug "Receive failed", err = e.msg
