# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import uri, eth_keys, strutils, net

type
  ENodeStatus* = enum
    ## ENode status codes
    Success,              ## Conversion operation succeed
    IncorrectNodeId,      ## Incorrect public key supplied
    IncorrectScheme,      ## Incorrect URI scheme supplied
    IncorrectIP,          ## Incorrect IP address supplied
    IncorrectPort,        ## Incorrect TCP port supplied
    IncorrectDiscPort,    ## Incorrect UDP discovery port supplied
    IncorrectUri,         ## Incorrect URI supplied
    IncompleteENode       ## Incomplete ENODE object

  Address* = object
    ## Network address object 
    ip*: IpAddress        ## IPv4/IPv6 address
    udpPort*: Port        ## UDP discovery port number
    tcpPort*: Port        ## TCP port number

  ENode* = object
    ## ENode object
    pubkey*: PublicKey    ## Node public key
    address*: Address     ## Node address

  ENodeException* = object of Exception

proc raiseENodeError(status: ENodeStatus) =
  if status == IncorrectIP:
    raise newException(ENodeException, "Incorrect IP address")
  elif status == IncorrectPort:
    raise newException(ENodeException, "Incorrect port number")
  elif status == IncorrectDiscPort:
    raise newException(ENodeException, "Incorrect discovery port number")
  elif status == IncorrectUri:
    raise newException(ENodeException, "Incorrect URI")
  elif status == IncorrectScheme:
    raise newException(ENodeException, "Incorrect scheme")
  elif status == IncorrectNodeId:
    raise newException(ENodeException, "Incorrect node id")
  elif status == IncompleteENode:
    raise newException(ENodeException, "Incomplete enode")

proc initENode*(e: string, node: var ENode): ENodeStatus =
  ## Initialize ENode ``node`` from URI string ``uri``.
  var
    uport: int = 0
    tport: int = 0
    uri: Uri = initUri()
    data: string

  if len(e) == 0:
    return IncorrectUri

  parseUri(e, uri)

  if len(uri.scheme) == 0 or uri.scheme.toLowerAscii() != "enode":
    return IncorrectScheme

  if len(uri.username) != 128:
    return IncorrectNodeId

  for i in uri.username:
    if i notin {'A'..'F', 'a'..'f', '0'..'9'}:
      return IncorrectNodeId

  if len(uri.password) != 0 or len(uri.path) != 0 or len(uri.anchor) != 0:
    return IncorrectUri

  if len(uri.hostname) == 0:
    return IncorrectIP

  try:
    if len(uri.port) == 0:
      return IncorrectPort
    tport = parseInt(uri.port)
    if tport <= 0 or tport > 65535:
      return IncorrectPort
  except:
    return IncorrectPort

  if len(uri.query) > 0:
    if not uri.query.toLowerAscii().startsWith("discport="):
      return IncorrectDiscPort
    try:
      uport = parseInt(uri.query[9..^1])
      if uport <= 0 or uport > 65535:
        return IncorrectDiscPort
    except:
      return IncorrectDiscPort
  else:
    uport = tport

  try:
    data = parseHexStr(uri.username)
    if recoverPublicKey(cast[seq[byte]](data),
                        node.pubkey) != EthKeysStatus.Success:
      return IncorrectNodeId
  except:
    return IncorrectNodeId

  try:
    node.address.ip = parseIpAddress(uri.hostname)
  except:
    zeroMem(addr node.pubkey, KeyLength * 2)
    return IncorrectIP

  node.address.tcpPort = Port(tport)
  node.address.udpPort = Port(uport)
  result = Success

proc initENode*(uri: string): ENode {.inline.} =
  ## Returns ENode object from URI string ``uri``.
  let res = initENode(uri, result)
  if res != Success:
    raiseENodeError(res)

proc isCorrect*(n: ENode): bool =
  ## Returns ``true`` if ENode ``n`` is properly filled.
  if n.address.ip.family notin {IpAddressFamily.IPv4, IpAddressFamily.IPv6}:
    return false
  if n.address.tcpPort == Port(0):
    return false
  if n.address.udpPort == Port(0):
    return false
  result = false
  for i in n.pubkey.data:
    if i != 0x00'u8:
      result = true
      break

proc `$`*(n: ENode): string =
  ## Returns string representation of ENode.
  var ipaddr: string
  if not isCorrect(n):
    raiseENodeError(IncompleteENode)
  if n.address.ip.family == IpAddressFamily.IPv4:
    ipaddr = $(n.address.ip)
  else:
    ipaddr = "[" & $(n.address.ip) & "]"
  result = newString(0)
  result.add("enode://")
  result.add($n.pubkey)
  result.add("@")
  result.add(ipaddr)
  result.add(":")
  result.add($int(n.address.tcpPort))
  if uint16(n.address.udpPort) != uint16(n.address.tcpPort):
    result.add("?")
    result.add("discport=")
    result.add($int(n.address.udpPort))
