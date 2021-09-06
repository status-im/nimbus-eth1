# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  eth/common,
  stew/results

type
  EcRecoverMode = enum
    useEc1Recover       ## the original version, based on `lru_cache`
    useEc2Recover       ## a new version, based on `keequ`
    useEc2x1Recover     ## new version verified against old version

const
  #ecRecoverMode = useEc1Recover
  #ecRecoverMode = useEc2Recover
  ecRecoverMode = useEc2x1Recover


when ecRecoverMode == useEc1Recover:
  import
    ./ec_recover/ec1recover
  export
    ec1recover.EcRecover,
    ec1recover.append,
    ec1recover.ecRecover,
    ec1recover.initEcRecover,
    ec1recover.read


when ecRecoverMode == useEc2Recover:
  import
    ./ec_recover/ec2recover
  export
    ec2recover.EcRecover,
    ec2recover.append,
    ec2recover.ecRecover,
    ec2recover.init,
    ec2recover.initEcRecover,
    ec2recover.len,
    ec2recover.read


when ecRecoverMode == useEc2x1Recover:
  import
    ../transaction,
    ./ec_recover/[ec1recover, ec2recover, ec_helpers]
  type
    EcRecover* = object
      ec1: ec1recover.EcRecover
      ec2: ec2recover.EcRecover

  proc ecRecover*(hdr: BlockHeader): auto {.inline.} =
    result = ec2recover.ecRecover(hdr)
    doAssert result == ec1recover.ecRecover(hdr)

  proc ecRecover*(tx: var Transaction): auto =
    result = ec2recover.ecRecover(tx)
    var ethAddr: EthAddress
    doAssert result.isOk == tx.getSender(ethAddr)
    if result.isOK:
      doAssert result.value == ethAddr

  proc ecRecover*(tx: Transaction): auto =
    result = ec2recover.ecRecover(tx)
    var ethAddr: EthAddress
    doAssert result.isOk == tx.getSender(ethAddr)
    if result.isOK:
      doAssert result.value == ethAddr

  proc len*(e: var EcRecover): int {.inline.} =
    e.ec2.len

  proc init*(e: var EcRecover;
             cacheSize = ec2recover.INMEMORY_SIGNATURES) {.inline.} =
    e.ec1.initEcRecover(cacheSize)
    e.ec2.init(cacheSize)

  proc initEcRecover*: EcRecover {.inline.} =
    result.init

  proc ecRecover*(e: var EcRecover; hdr: BlockHeader): auto {.inline.} =
    result = e.ec2.ecRecover(hdr)
    doAssert result == e.ec1.ecRecover(hdr)
    doAssert e.ec1.similarKeys(e.ec2).isOk

  proc append*(rw: var RlpWriter; e: EcRecover)
      {.inline, raises: [Defect,KeyError].} =
    rw.append((e.ec1,e.ec2))

  proc read*(rlp: var Rlp; Q: type EcRecover): Q
      {.inline, raises: [Defect,KeyError].} =
    (result.ec1, result.ec2) = rlp.read((type result.ec1, type result.ec2))

# End
