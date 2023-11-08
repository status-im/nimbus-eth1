# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  std/os,
  ./test_types

const
  snapStorage0* = AccountsSample(
    name: "Storage0",
    file: "storage" / "storages0___0___1_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapStorage1* = AccountsSample(
    name: "Storage1",
    file: "storage" / "storages1___2___9_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapStorage2* = AccountsSample(
    name: "Storage2",
    file: "storage" / "storages2__10__17_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapStorage3* = AccountsSample(
    name: "Storage3",
    file: "storage" / "storages3__18__25_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapStorage4* = AccountsSample(
    name: "Storage4",
    file: "storage" / "storages4__26__33_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapStorage5* = AccountsSample(
    name: "Storage5",
    file: "storage" / "storages5__34__41_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapStorage6* = AccountsSample(
    name: "Storage6",
    file: "storage" / "storages6__42__50_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapStorage7* = AccountsSample(
    name: "Storage7",
    file: "storage" / "storages7__51__59_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapStorage8* = AccountsSample(
    name: "Storage8",
    file: "storage" / "storages8__60__67_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapStorage9* = AccountsSample(
    name: "Storage9",
    file: "storage" / "storages9__68__75_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapStorageA* = AccountsSample(
    name: "StorageA",
    file: "storage" / "storagesA__76__83_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapStorageB* = AccountsSample(
    name: "StorageB",
    file: "storage" / "storagesB__84__92_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapStorageC* = AccountsSample(
    name: "StorageC",
    file: "storage" / "storagesC__93_101_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapStorageD* = AccountsSample(
    name: "StorageD",
    file: "storage" / "storagesD_102_109_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapStorageE* = AccountsSample(
    name: "StorageE",
    file: "storage" / "storagesE_110_118_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapStorageF* = AccountsSample(
    name: "StorageF",
    file: "storage" / "storagesF_119_126_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapStorageG* = AccountsSample(
    name: "StorageG",
    file: "storage" / "storagesG_127_129_dump.txt.gz",
    firstItem: 0,
    lastItem: high(int))

  snapStorageList* = [
    snapStorage0, snapStorage1, snapStorage2, snapStorage3, snapStorage4,
    snapStorage5, snapStorage6, snapStorage7, snapStorage8, snapStorage9,
    snapStorageA, snapStorageB, snapStorageC, snapStorageD, snapStorageE,
    snapStorageF, snapStorageG]

# End
