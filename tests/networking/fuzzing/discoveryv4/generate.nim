# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[times, os, strformat, strutils],
  chronos, stew/byteutils, stint, chronicles, nimcrypto,
  eth/[keys, rlp],
  ../../../../execution_chain/networking/discoveryv4,
  ../../p2p_test_helper,
  ../fuzzing_helpers

template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]
const inputsDir = &"{sourceDir}{DirSep}generated-input{DirSep}"

const EXPIRATION = 3600 * 24 * 365 * 10
proc expiration(): uint32 = uint32(epochTime() + EXPIRATION)

proc generate() =
  ## Generate some valid inputs where one can start fuzzing with
  let
    fromAddr = localAddress(30303)
    toAddr = localAddress(30304)
    peerKey = PrivateKey.fromHex("a2b50376a79b1a8c8a3296485572bdfbf54708bb46d3c25d73d2723aaaf6a617")[]

  # valid data for a Ping packet
  block:
    let payload = rlp.encode((uint64 4, fromAddr, toAddr, expiration()))
    let encodedData = @[1.byte] & payload
    debug "Ping", data=byteutils.toHex(encodedData)

    encodedData.toFile(inputsDir & "ping")

  # valid data for a Pong packet
  block:
    let token = keccak256.digest(@[byte 0])
    let payload = rlp.encode((toAddr, token , expiration()))
    let encodedData = @[2.byte] & payload
    debug "Pong", data=byteutils.toHex(encodedData)

    encodedData.toFile(inputsDir & "pong")

  # valid data for a FindNode packet
  block:
    var data: array[64, byte]
    data[32 .. ^1] = peerKey.toPublicKey().toNodeId().toBytesBE()
    let payload = rlp.encode((data, expiration()))
    let encodedData = @[3.byte] & @payload
    debug "FindNode", data=byteutils.toHex(encodedData)

    encodedData.toFile(inputsDir & "findnode")

  # valid data for a Neighbours packet
  block:
    let
      n1Addr = localAddress(30305)
      n2Addr = localAddress(30306)
      n1Key = PrivateKey.fromHex(
        "a2b50376a79b1a8c8a3296485572bdfbf54708bb46d3c25d73d2723aaaf6a618")[]
      n2Key = PrivateKey.fromHex(
        "a2b50376a79b1a8c8a3296485572bdfbf54708bb46d3c25d73d2723aaaf6a619")[]

    type Neighbour = tuple[ip: IpAddress, udpPort, tcpPort: Port, pk: PublicKey]
    var nodes = newSeqOfCap[Neighbour](2)

    nodes.add((n1Addr.ip, n1Addr.udpPort, n1Addr.tcpPort, n1Key.toPublicKey()))
    nodes.add((n2Addr.ip, n2Addr.udpPort, n2Addr.tcpPort, n2Key.toPublicKey()))

    let payload = rlp.encode((nodes, expiration()))
    let encodedData = @[4.byte] & @payload
    debug "Neighbours", data=byteutils.toHex(encodedData)

    encodedData.toFile(inputsDir & "neighbours")

discard existsOrCreateDir(inputsDir)
generate()
