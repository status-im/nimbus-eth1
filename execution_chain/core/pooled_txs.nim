# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  eth/common/transactions,
  web3/primitives

export
  transactions,
  primitives

type
  KzgBlob* = primitives.Blob

  WrapperVersion* = enum
    WrapperVersionEIP4844  # 0
    WrapperVersionEIP7594  # 1

  BlobsBundle* = ref object
    wrapperVersion*: WrapperVersion
    blobs*: seq[KzgBlob]
    commitments*: seq[KzgCommitment]
    proofs*: seq[KzgProof]
      # The 'proofs' field is shared between
      # EIP-4844's 'proofs' and EIP-7594's
      # cell_proofs

  PooledTransaction* = object
    tx*: Transaction
    blobsBundle*: BlobsBundle       # EIP-4844
