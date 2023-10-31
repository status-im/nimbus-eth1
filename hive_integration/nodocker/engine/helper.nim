import
  eth/[common, rlp],
  ../../../nimbus/beacon/execution_types,
  ../../../nimbus/beacon/web3_eth_conv

proc txInPayload*(payload: ExecutionPayload, txHash: common.Hash256): bool =
  for txBytes in payload.transactions:
    let currTx = rlp.decode(common.Blob txBytes, Transaction)
    if rlpHash(currTx) == txHash:
      return true
