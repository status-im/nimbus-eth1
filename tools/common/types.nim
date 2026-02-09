# Nimbus
# Copyright (c) 2022-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

type
  TestFork* = enum
    Frontier
    Homestead
    EIP150
    EIP158
    Byzantium
    Constantinople
    ConstantinopleFix
    Istanbul
    FrontierToHomesteadAt5
    HomesteadToEIP150At5
    HomesteadToDaoAt5
    EIP158ToByzantiumAt5
    ByzantiumToConstantinopleAt5
    ByzantiumToConstantinopleFixAt5
    ConstantinopleFixToIstanbulAt5
    Berlin
    BerlinToLondonAt5
    London
    ArrowGlacier
    GrayGlacier
    Merge
    Paris
    ArrowGlacierToParisAtDiffC0000
    Shanghai
    ParisToShanghaiAtTime15k
    Cancun
    ShanghaiToCancunAtTime15k
    Prague
    CancunToPragueAtTime15k
    Osaka
    PragueToOsakaAtTime15k
    BPO1
    OsakaToBPO1AtTime15k
    BPO2
    BPO1ToBPO2AtTime15k
    BPO3
    BPO2ToBPO3AtTime15k
    BPO4
    BPO3ToBPO4AtTime15k
    BPO5
    BPO4ToBPO5AtTime15k
    Amsterdam
    BPO2ToAmsterdamAtTime15k

  LogLevel* = enum
    Silent
    Error
    Warn
    Info
    Debug
    Detail
