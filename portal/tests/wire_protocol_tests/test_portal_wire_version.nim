# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  std/net,
  unittest2,
  eth/enr/enr,
  eth/common/keys,
  ../../network/wire/portal_protocol_version

suite "Portal Wire Protocol Version":
  setup:
    let
      pk = PrivateKey
        .fromHex("5d2908f3f09ea1ff2e327c3f623159639b00af406e9009de5fd4b910fc34049d")
        .expect("valid private key")
      ip = Opt.none(IpAddress)
      port = Opt.none(Port)

  test "ENR with no Portal version field":
    let
      localPortalEnrField = PortalEnrField.init(0'u8, 1'u8, 1.chainId())
      enr = Record.init(1, pk, ip, port, port, port, []).expect("Valid ENR init")

    let version = enr.highestCommonPortalVersionAndChain(localPortalEnrField)
    check:
      version.isOk()
      version.get() == 0'u8

  test "ENR with empty Portal ENR field list":
    let
      localPortalEnrField = PortalEnrField.init(0'u8, 1'u8, 1.chainId())
      portalEnrField = @[byte 0xc0] # Empty rlp list
      customEnrFields = [toFieldPair(portalEnrKey, portalEnrField)]
      enr = Record.init(1, pk, ip, port, port, port, customEnrFields).expect(
          "Valid ENR init"
        )

    let version = enr.highestCommonPortalVersionAndChain(localPortalEnrField)
    check version.isErr()

  test "ENR with unsupported Portal versions":
    let
      localPortalEnrField = PortalEnrField.init(0'u8, 1'u8, 1.chainId())
      portalEnrField = PortalEnrField.init(2'u8, 255'u8, 2.chainId())

      customEnrFields = [toFieldPair(portalEnrKey, rlp.encode(portalEnrField))]
      enr = Record.init(1, pk, ip, port, port, port, customEnrFields).expect(
          "Valid ENR init"
        )

    let version = enr.highestCommonPortalVersionAndChain(localPortalEnrField)
    check version.isErr()

  test "ENR with supported Portal version":
    let
      localPortalEnrField = PortalEnrField.init(0'u8, 1'u8, 1.chainId())
      portalEnrField = PortalEnrField.init(1'u8, 3'u8, 1.chainId())

      customEnrFields = [toFieldPair(portalEnrKey, rlp.encode(portalEnrField))]
      enr = Record.init(1, pk, ip, port, port, port, customEnrFields).expect(
          "Valid ENR init"
        )

    let version = enr.highestCommonPortalVersionAndChain(localPortalEnrField)
    check:
      version.isOk()
      version.get() == 1'u8

  test "ENR with multiple supported Portal versions":
    let
      localPortalEnrField = PortalEnrField.init(0'u8, 2'u8, 1.chainId())
      portalEnrField = PortalEnrField.init(0'u8, 3'u8, 1.chainId())
      customEnrFields = [toFieldPair(portalEnrKey, rlp.encode(portalEnrField))]
      enr = Record.init(1, pk, ip, port, port, port, customEnrFields).expect(
          "Valid ENR init"
        )

    let version = enr.highestCommonPortalVersionAndChain(localPortalEnrField)
    check:
      version.isOk()
      version.get() == 2'u8

  test "ENR with invalid Portal version range (min > max)":
    let
      localPortalEnrField = PortalEnrField.init(0'u8, 1'u8, 1.chainId())
      portalEnrField = PortalEnrField.init(2'u8, 1'u8, 1.chainId())
      customEnrFields = [toFieldPair(portalEnrKey, rlp.encode(portalEnrField))]
      enr = Record.init(1, pk, ip, port, port, port, customEnrFields).expect(
          "Valid ENR init"
        )

    let version = enr.highestCommonPortalVersionAndChain(localPortalEnrField)
    check version.isErr()

  test "ENR with supported Portal version but different chain id":
    let
      localPortalEnrField = PortalEnrField.init(0'u8, 1'u8, 1.chainId())
      portalEnrField = PortalEnrField.init(1'u8, 3'u8, 2.chainId())

      customEnrFields = [toFieldPair(portalEnrKey, rlp.encode(portalEnrField))]
      enr = Record.init(1, pk, ip, port, port, port, customEnrFields).expect(
          "Valid ENR init"
        )

    let version = enr.highestCommonPortalVersionAndChain(localPortalEnrField)
    check version.isErr()
