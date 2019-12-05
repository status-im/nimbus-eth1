# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# XXX: when all but a relative few dozen, say, GeneralStateTests run, remove this,
# but for now, this enables some CI use before that to prevent regressions. In the
# separate file here because it would otherwise just distract. Could use all sorts
# of O(1) or O(log n) lookup structures, or be more careful to only initialize the
# table once, but notion's that it should shrink reasonable quickly and disappear,
# being mostly used for short-term regression prevention.
func allowedFailingGeneralStateTest*(folder, name: string): bool =
  let allowedFailingGeneralStateTests = @[
    # conflicts between native int and big int.
    # gasFee calculation in modexp precompiled
    # contracts
    "modexp.json",
    # perhaps a design flaw with create/create2 opcode.
    # a conflict between balance checker and
    # static call context checker
    "create2noCash.json",

    # Istanbul bc test
    # py-evm claims these tests are incorrect
    # nimbus also agree
    "RevertInCreateInInit.json",
    "RevertInCreateInInitCreate2.json",
    "InitCollision.json",

    # Failure once spotted on Travis CI Linux AMD64:
    # "out of memorysubtest no: 7 failed"
    # "randomStatetest159.json",
  ]
  result = name in allowedFailingGeneralStateTests
