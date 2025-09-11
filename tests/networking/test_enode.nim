# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import
  std/[net, options],
  unittest2,
  ../../execution_chain/networking/[discoveryv4/enode, bootnodes]

suite "ENode":
  test "Go-Ethereum tests":
    const enodes = [
      "http://foobar",
      "enode://01010101@123.124.125.126:3",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@hostname:3",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@127.0.0.1:foo",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@127.0.0.1:3?discport=foo",
      "01010101",
      "enode://01010101",
      "://foo",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@127.0.0.1:52150",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@[::]:52150",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@[2001:db8:3c4d:15::abcd:ef12]:52150",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@127.0.0.1:52150?discport=22334",
    ]

    const results = [
      some IncorrectScheme,
      some IncorrectNodeId,
      some IncorrectIP,
      some IncorrectPort,
      some IncorrectDiscPort,
      some IncorrectScheme,
      some IncorrectNodeId,
      some IncorrectScheme,
      none(ENodeError),
      none(ENodeError),
      none(ENodeError),
      none(ENodeError),
    ]

    for index in 0..<len(enodes):
      let res = ENode.fromString(enodes[index])
      check (results[index].isSome and res.error == results[index].get) or
        res.isOk

      if res.isOk:
        check enodes[index] == $res[]

  test "Custom validation tests":
    const enodes = [
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@256.0.0.1:52150",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@1.256.0.1:52150",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@1.1.256.1:52150",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@1.1.1.256:52150",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439:@1.1.1.255:52150",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439:bar@1.1.1.255:52150",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@1.1.1.255:-1",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@1.1.1.255:65536",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@1.1.1.255:1024?discport=-1",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@1.1.1.255:1024?discport=65536",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@1.1.1.255:1024?discport=65535#bar",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a439@",
      "enode://1dd9d65c4552b5eb43d5ad55a2ee3f56c6cbc1c64a5c8d659f51fcd51bace24351232b8d7821617d2b29b54b81cdefb9b3e9c37d7fd5f63270bcc9e1a6f6a43Z@1.1.1.1:25?discport=22"
    ]

    const results = [
      some IncorrectIP,
      some IncorrectIP,
      some IncorrectIP,
      some IncorrectIP,
      none(ENodeError),
      some IncorrectUri,
      some IncorrectPort,
      some IncorrectPort,
      some IncorrectDiscPort,
      some IncorrectDiscPort,
      some IncorrectUri,
      some IncorrectIP,
      some IncorrectNodeId
    ]

    for index in 0..<len(enodes):
      let res = ENode.fromString(enodes[index])

      check (results[index].isSome and res.error == results[index].get) or
        res.isOk

  test "Bootnodes test":
    var boot: BootstrapNodes
    check getBootstrapNodes("mainnet", boot) == Result[void, string].ok()
    check getBootstrapNodes("holesky", boot) == Result[void, string].ok()
    check getBootstrapNodes("sepolia", boot) == Result[void, string].ok()
    check getBootstrapNodes("hoodi", boot) == Result[void, string].ok()

    var boot1: BootstrapNodes
    check loadBootstrapNodes("tests/networking/bootnodes.yaml", boot1) == Result[void, string].ok()

    let bn = [
      "enode://ac906289e4b7f12df423d654c5a962b6ebe5b3a74cc9e06292a85221f9a64a6f1cfdd6b714ed6dacef51578f92b34c60ee91e9ede9c7f8fadc4d347326d95e2b@146.190.13.128:30303",
      "enr:-KG4QC9Wm32mtzB5Fbj2ri2TEKglHmIWgvwTQCvNHBopuwpNAi1X6qOsBg_Z1-Bee-kfSrhzUQZSgDUyfH5outUprtoBgmlkgnY0gmlwhHEel3eDaXA2kP6AAAAAAAAAAlBW__4Srr-Jc2VjcDI1NmsxoQO7KE63Z4eSI55S1Yn7q9_xFkJ1Wt-a3LgiXuKGs19s0YN1ZHCCIyiEdWRwNoIjKA",
      "tests/networking/bootnodes.yaml"
    ]
    var boot2: BootstrapNodes
    check parseBootstrapNodes(bn, boot2) == Result[void, string].ok()
    check boot2.enrs.len == boot1.enrs.len + 1
    check boot2.enodes.len == boot1.enodes.len + 1
