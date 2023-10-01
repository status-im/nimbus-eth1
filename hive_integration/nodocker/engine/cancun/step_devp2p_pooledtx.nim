import
  ./step

# A step that requests a Transaction hash via P2P and expects the correct full blob tx
type DevP2PRequestPooledTransactionHash struct {
  # Client index to request the transaction hash from
  ClientIndex uint64
  # Transaction Index to request
  TransactionIndexes []uint64
  # Wait for a new pooled transaction message before actually requesting the transaction
  WaitForNewPooledTransaction bool
}

func (step DevP2PRequestPooledTransactionHash) Execute(t *CancunTestContext) error {
  # Get client index's enode
  if step.ClientIndex >= uint64(len(t.TestEngines)) {
    return error "invalid client index %d", step.ClientIndex)
  }
  engine = t.Engines[step.ClientIndex]
  conn, err = devp2p.PeerEngineClient(engine, env.clMock)
  if err != nil {
    return error "error peering engine client: %v", err)
  }
  defer conn.Close()
  info "Connected to client %d, remote public key: %s", step.ClientIndex, conn.RemoteKey())

  var (
    txHashes = make([]Hash256, len(step.TransactionIndexes))
    txs      = make([]typ.Transaction, len(step.TransactionIndexes))
    ok       bool
  )
  for i, txIndex = range step.TransactionIndexes {
    txHashes[i], ok = t.TestBlobTxPool.HashesByIndex[txIndex]
    if !ok {
      return error "transaction index %d not found", step.TransactionIndexes[0])
    }
    txs[i], ok = t.TestBlobTxPool.transactions[txHashes[i]]
    if !ok {
      return error "transaction %s not found", txHashes[i].String())
    }
  }

  # Timeout value for all requests
  timeout = 20 * time.Second

  # Wait for a new pooled transaction message
  if step.WaitForNewPooledTransaction {
    msg, err = conn.WaitForResponse(timeout, 0)
    if err != nil {
      return errors.Wrap(err, "error waiting for response")
    }
    switch msg = msg.(type) {
    case *devp2p.NewPooledTransactionHashes:
      if len(msg.Hashes) != len(txHashes) {
        return error "expected %d hashes, got %d", len(txHashes), len(msg.Hashes))
      }
      if len(msg.Types) != len(txHashes) {
        return error "expected %d types, got %d", len(txHashes), len(msg.Types))
      }
      if len(msg.Sizes) != len(txHashes) {
        return error "expected %d sizes, got %d", len(txHashes), len(msg.Sizes))
      }
      for i = 0; i < len(txHashes); i++ {
        hash, typ, size = msg.Hashes[i], msg.Types[i], msg.Sizes[i]
        # Get the transaction
        tx, ok = t.TestBlobTxPool.transactions[hash]
        if !ok {
          return error "transaction %s not found", hash.String())
        }

        if typ != tx.Type() {
          return error "expected type %d, got %d", tx.Type(), typ)
        }

        b, err = tx.MarshalBinary()
        if err != nil {
          return errors.Wrap(err, "error marshaling transaction")
        }
        if size != uint32(len(b)) {
          return error "expected size %d, got %d", len(b), size)
        }
      }
    default:
      return error "unexpected message type: %T", msg)
    }
  }

  # Send the request for the pooled transactions
  getTxReq = &devp2p.GetPooledTransactions{
    RequestId:                   1234,
    GetPooledTransactionsPacket: txHashes,
  }
  if size, err = conn.Write(getTxReq); err != nil {
    return errors.Wrap(err, "could not write to conn")
  else:
    info "Wrote %d bytes to conn", size)
  }

  # Wait for the response
  msg, err = conn.WaitForResponse(timeout, getTxReq.RequestId)
  if err != nil {
    return errors.Wrap(err, "error waiting for response")
  }
  switch msg = msg.(type) {
  case *devp2p.PooledTransactions:
    if len(msg.PooledTransactionsBytesPacket) != len(txHashes) {
      return error "expected %d txs, got %d", len(txHashes), len(msg.PooledTransactionsBytesPacket))
    }
    for i, txBytes = range msg.PooledTransactionsBytesPacket {
      tx = txs[i]

      expBytes, err = tx.MarshalBinary()
      if err != nil {
        return errors.Wrap(err, "error marshaling transaction")
      }

      if len(expBytes) != len(txBytes) {
        return error "expected size %d, got %d", len(expBytes), len(txBytes))
      }

      if !bytes.Equal(expBytes, txBytes) {
        return error "expected tx %#x, got %#x", expBytes, txBytes)
      }

    }
  default:
    return error "unexpected message type: %T", msg)
  }
  return nil
}

func (step DevP2PRequestPooledTransactionHash) Description() string {
  return fmt.Sprintf("DevP2PRequestPooledTransactionHash: client %d, transaction indexes %v", step.ClientIndex, step.TransactionIndexes)
}