# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms

{.push raises: [].}

import
  std/importutils,
  ./discoveryv4/enode,
  eth/net/utils,
  eth/p2p/discoveryv5/enr {.all.}

export
  enr.Record, enr.fromURI, enode

func to*(enode: ENode, _: type enr.Record): enr.Record =
  privateAccess(enr.Field)

  var record = enr.Record(
    seqNum: 1'u64,
    publicKey: enode.pubkey,
  )

  record.pairs.insert(("id", Field(kind: kString, str: "v4")))
  record.pairs.insert(("secp256k1",
    Field(kind: kBytes, bytes: @(enode.pubkey.toRawCompressed()))))
  record.pairs.insertAddress(
    ip = Opt.some(enode.address.ip),
    tcpPort = Opt.some(enode.address.tcpPort),
    udpPort = Opt.some(enode.address.udpPort)
  )

  record

func to*(enodes: openArray[ENode], _: type enr.Record): seq[enr.Record] =
  result = newSeqOfCap[enr.Record](enodes.len)
  for enode in enodes:
    result.add enode.to(enr.Record)

func fromEnr*(T: type ENode, r: enr.Record): ENodeResult[ENode] =
  let
    # TODO: there must always be a public key, else no signature verification
    # could have been done and no Record would exist here.
    # TypedRecord should be reworked not to have public key as an option.
    pk = r.get(PublicKey).get()
    tr = TypedRecord.fromRecord(r)#.expect("id in valid record")

  if tr.ip.isNone():
    return err(IncorrectIP)
  if tr.udp.isNone():
    return err(IncorrectDiscPort)
  if tr.tcp.isNone():
    return err(IncorrectPort)

  ok(ENode(
    pubkey: pk,
    address: enode.Address(
      ip: utils.ipv4(tr.ip.get()),
      udpPort: Port(tr.udp.get()),
      tcpPort: Port(tr.tcp.get())
    )
  ))
