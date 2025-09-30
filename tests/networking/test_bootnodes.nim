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
  std/[net],
  unittest2,
  ../../execution_chain/networking/bootnodes

suite "Bootnodes":
  test "Bootnodes test":
    var boot: BootstrapNodes
    check getBootstrapNodes("mainnet", boot).isOk
    check getBootstrapNodes("holesky", boot).isOk
    check getBootstrapNodes("sepolia", boot).isOk
    check getBootstrapNodes("hoodi", boot).isOk

    var boot1: BootstrapNodes
    check loadBootstrapNodes("tests/networking/bootnodes.yaml", boot1).isOk
    check boot1.enrs.len > 0
    check boot1.enodes.len > 0

    let bn = [
      "enode://ac906289e4b7f12df423d654c5a962b6ebe5b3a74cc9e06292a85221f9a64a6f1cfdd6b714ed6dacef51578f92b34c60ee91e9ede9c7f8fadc4d347326d95e2b@146.190.13.128:30303",
      "enr:-KG4QC9Wm32mtzB5Fbj2ri2TEKglHmIWgvwTQCvNHBopuwpNAi1X6qOsBg_Z1-Bee-kfSrhzUQZSgDUyfH5outUprtoBgmlkgnY0gmlwhHEel3eDaXA2kP6AAAAAAAAAAlBW__4Srr-Jc2VjcDI1NmsxoQO7KE63Z4eSI55S1Yn7q9_xFkJ1Wt-a3LgiXuKGs19s0YN1ZHCCIyiEdWRwNoIjKA",
    ]
    var boot2 = boot1
    check parseBootstrapNodes(bn, boot2).isOk
    check boot2.enrs.len == boot1.enrs.len + 1
    check boot2.enodes.len == boot1.enodes.len + 1
