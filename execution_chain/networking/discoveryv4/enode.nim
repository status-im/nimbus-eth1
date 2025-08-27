# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[uri, strutils, net],
  pkg/chronicles,
  eth/common/keys,
  json_serialization/writer

export keys, writeValue

type
  ENodeError* = enum
    ## ENode status codes
    IncorrectNodeId   = "enode: incorrect public key"
    IncorrectScheme   = "enode: incorrect URI scheme"
    IncorrectIP       = "enode: incorrect IP address"
    IncorrectPort     = "enode: incorrect TCP port"
    IncorrectDiscPort = "enode: incorrect UDP discovery port"
    IncorrectUri      = "enode: incorrect URI"
    IncompleteENode   = "enode: incomplete ENODE object"

  Address* = object
    ## Network address object
    ip*: IpAddress        ## IPv4/IPv6 address
    udpPort*: Port        ## UDP discovery port number
    tcpPort*: Port        ## TCP port number

  ENode* = object
    ## ENode is a legacy URL-style identifier for Ethereum node that supports
    ## a pubkey, IP address/port and an optional discovery port - it has mostly
    ## been superseded by ENR.
    ## https://ethereum.org/en/developers/docs/networking-layer/network-addresses/#enode
    pubkey*: PublicKey    ## Node public key
    address*: Address     ## Node address

  ENodeResult*[T] = Result[T, ENodeError]

proc mapErrTo[T, E](r: Result[T, E], v: static ENodeError): ENodeResult[T] =
  r.mapErr(proc (e: E): ENodeError = v)

proc fromString*(T: type ENode, e: string): ENodeResult[ENode] =
  ## Initialize ENode ``node`` from URI string ``uri``.
  var
    uport: int = 0
    tport: int = 0
    uri: Uri = initUri()

  if len(e) == 0:
    return err(IncorrectUri)

  parseUri(e, uri)

  if len(uri.scheme) == 0 or uri.scheme.toLowerAscii() != "enode":
    return err(IncorrectScheme)

  if len(uri.username) != 128:
    return err(IncorrectNodeId)

  for i in uri.username:
    if i notin {'A'..'F', 'a'..'f', '0'..'9'}:
      return err(IncorrectNodeId)

  if len(uri.password) != 0 or len(uri.path) != 0 or len(uri.anchor) != 0:
    return err(IncorrectUri)

  if len(uri.hostname) == 0:
    return err(IncorrectIP)

  try:
    if len(uri.port) == 0:
      return err(IncorrectPort)
    tport = parseInt(uri.port)
    if tport <= 0 or tport > 65535:
      return err(IncorrectPort)
  except ValueError:
    return err(IncorrectPort)

  if len(uri.query) > 0:
    if not uri.query.toLowerAscii().startsWith("discport="):
      return err(IncorrectDiscPort)
    try:
      uport = parseInt(uri.query[9..^1])
      if uport <= 0 or uport > 65535:
        return err(IncorrectDiscPort)
    except ValueError:
      return err(IncorrectDiscPort)
  else:
    uport = tport

  var ip: IpAddress
  try:
    ip = parseIpAddress(uri.hostname)
  except ValueError:
    return err(IncorrectIP)

  let pubkey = ? PublicKey.fromHex(uri.username).mapErrTo(IncorrectNodeId)

  ok(ENode(
    pubkey: pubkey,
    address: Address(
      ip: ip,
      tcpPort: Port(tport),
      udpPort: Port(uport)
    )
  ))

proc `$`*(n: ENode): string =
  ## Returns string representation of ENode.
  var ipaddr: string
  if n.address.ip.family == IpAddressFamily.IPv4:
    ipaddr = $(n.address.ip)
  else:
    ipaddr = "[" & $(n.address.ip) & "]"
  result = newString(0)
  result.add("enode://")
  result.add($n.pubkey)
  result.add("@")
  result.add(ipaddr)
  if uint16(n.address.tcpPort) != 0:
    result.add(":")
    result.add($int(n.address.tcpPort))
  if uint16(n.address.udpPort) != uint16(n.address.tcpPort):
    result.add("?")
    result.add("discport=")
    result.add($int(n.address.udpPort))

proc `$`*(a: Address): string =
  result.add($a.ip)
  result.add(":" & $a.udpPort)
  result.add(":" & $a.tcpPort)

proc writeValue*(w: var JsonWriter, a: Address) {.raises: [IOError].} =
  w.writeValue $a

proc writeValue*(w: var JsonWriter, a: ENode) {.raises: [IOError].} =
  w.writeValue $a
