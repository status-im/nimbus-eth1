# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  std/net,
  unittest2,
  eth/p2p/discoveryv5/enr,
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
      localSupportedVersions = PortalVersionValue(@[0'u8, 1'u8])
      enr = Record.init(1, pk, ip, port, port, []).expect("Valid ENR init")

    let version = enr.highestCommonPortalVersion(localSupportedVersions)
    check:
      version.isOk()
      version.get() == 0'u8

  test "ENR with empty Portal version list":
    let
      localSupportedVersions = PortalVersionValue(@[0'u8, 1'u8])
      portalVersions = PortalVersionValue(@[])
      customEnrFields = [toFieldPair(portalVersionKey, SSZ.encode(portalVersions))]
      enr = Record.init(1, pk, ip, port, port, customEnrFields).expect("Valid ENR init")

    let version = enr.highestCommonPortalVersion(localSupportedVersions)
    check version.isErr()

  test "ENR with unsupported Portal versions":
    let
      localSupportedVersions = PortalVersionValue(@[0'u8, 1'u8])
      portalVersions = PortalVersionValue(@[255'u8, 100'u8, 2'u8])
      customEnrFields = [toFieldPair(portalVersionKey, SSZ.encode(portalVersions))]
      enr = Record.init(1, pk, ip, port, port, customEnrFields).expect("Valid ENR init")

    let version = enr.highestCommonPortalVersion(localSupportedVersions)
    check version.isErr()

  test "ENR with supported Portal version":
    let
      localSupportedVersions = PortalVersionValue(@[0'u8, 1'u8])
      portalVersions = PortalVersionValue(@[3'u8, 2'u8, 1'u8])
      customEnrFields = [toFieldPair(portalVersionKey, SSZ.encode(portalVersions))]
      enr = Record.init(1, pk, ip, port, port, customEnrFields).expect("Valid ENR init")

    let version = enr.highestCommonPortalVersion(localSupportedVersions)
    check:
      version.isOk()
      version.get() == 1'u8

  test "ENR with multiple supported Portal versions":
    let
      localSupportedVersions = PortalVersionValue(@[0'u8, 1'u8, 2'u8])
      portalVersions = PortalVersionValue(@[0'u8, 2'u8, 2'u8, 3'u8])
      customEnrFields = [toFieldPair(portalVersionKey, SSZ.encode(portalVersions))]
      enr = Record.init(1, pk, ip, port, port, customEnrFields).expect("Valid ENR init")

    let version = enr.highestCommonPortalVersion(localSupportedVersions)
    check:
      version.isOk()
      version.get() == 2'u8

  test "ENR with too many Portal versions":
    let
      localSupportedVersions = PortalVersionValue(@[0'u8, 1'u8, 2'u8])
      portalVersions =
        PortalVersionValue(@[0'u8, 1'u8, 2'u8, 3'u8, 4'u8, 5'u8, 6'u8, 7'u8, 8'u8])
      customEnrFields = [toFieldPair(portalVersionKey, SSZ.encode(portalVersions))]
      enr = Record.init(1, pk, ip, port, port, customEnrFields).expect("Valid ENR init")

    let version = enr.highestCommonPortalVersion(localSupportedVersions)
    check version.isErr()
