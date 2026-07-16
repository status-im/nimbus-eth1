# nimbus-execution-client
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import
  std/[net, strutils],
  unittest2,
  ../../execution_chain/networking/bootnodes

suite "Bootnodes":
  test "Bootnodes test":
    var boot: BootstrapNodes
    check getBootstrapNodes("mainnet", boot).isOk
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

  test "one malformed entry does not drop the rest of the list":
    let bn = [
      # discovery-only, TCP port 0 -> "enode: incorrect TCP port"
      "enode://a9ab68c77cb408e200cd1249202ee8f8d32a948fbdcc8c7b55e0afd7e7238b55e4d0b521f26f8020866e8af4b631825b599e6c5726d3b7573f20da488e0dd596@159.223.116.60:0?discport=9010",
      "enode://2c82017536b1b74b62aa2a81769f4a1213ac9edd3a1df43af5fd008f3305e92bfd9351db9881c9c09de2afc79d3f7f6c271cf2f7231f9021926c0674dc02035c@159.223.116.60:30303?discport=30303",
      "enode://c34353f4d5fcc777863c511a09b3b57f1a9df066578b3432fa1e58d8b0a5d35ca0456b9cd1c38bc9cf30ac9bfecf8b13f0712aae1f1ae5537df8794b622f8ad1@157.230.233.160:30303?discport=30303",
      "enode://fec6d370e61500d2b314a064fd371dbddde6ddcc5b864218dc8af597817e0c09d39dfb3ca29a109266ec9a5e77258f7820685f3a920b550aeedd4783786ee3a1@147.182.209.19:30303?discport=30303",
      "enode://40de465637bedc6675921cc565e48771ea69dace8f168a8906bb965537b9cbdbcf24714e1e5acb0c3f2d425523a60b79a544f97a51570848c0971cd27252669a@157.230.220.40:30303?discport=30303",
    ]
    var boot: BootstrapNodes
    let res = parseBootstrapNodes(bn, boot)
    # The bad entry is still reported...
    check res.isErr
    check "incorrect TCP port" in res.error
    # ...but the four valid nodes are accepted instead of being dropped.
    check boot.enodes.len == 4

  test "a fully valid list still succeeds":
    let bn = [
      "enode://2c82017536b1b74b62aa2a81769f4a1213ac9edd3a1df43af5fd008f3305e92bfd9351db9881c9c09de2afc79d3f7f6c271cf2f7231f9021926c0674dc02035c@159.223.116.60:30303?discport=30303",
      "enode://c34353f4d5fcc777863c511a09b3b57f1a9df066578b3432fa1e58d8b0a5d35ca0456b9cd1c38bc9cf30ac9bfecf8b13f0712aae1f1ae5537df8794b622f8ad1@157.230.233.160:30303?discport=30303",
    ]
    var boot: BootstrapNodes
    check parseBootstrapNodes(bn, boot).isOk
    check boot.enodes.len == 2
