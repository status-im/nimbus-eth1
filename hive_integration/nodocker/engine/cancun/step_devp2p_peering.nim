import
  ./step

# A step that attempts to peer to the client using devp2p, and checks the forkid of the client
type DevP2PClientPeering struct {
  # Client index to peer to
  ClientIndex uint64
}

func (step DevP2PClientPeering) Execute(t *CancunTestContext) error {
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

  # Sleep
  time.Sleep(1 * time.Second)

  # Timeout value for all requests
  timeout = 20 * time.Second

  # Send a ping request to verify that we are not immediately disconnected
  pingReq = &devp2p.Ping{}
  if size, err = conn.Write(pingReq); err != nil {
    return errors.Wrap(err, "could not write to conn")
  else:
    info "Wrote %d bytes to conn", size)
  }

  # Finally wait for the pong response
  msg, err = conn.WaitForResponse(timeout, 0)
  if err != nil {
    return errors.Wrap(err, "error waiting for response")
  }
  switch msg = msg.(type) {
  case *devp2p.Pong:
    info "Received pong response: %v", msg)
  default:
    return error "unexpected message type: %T", msg)
  }

  return nil
}

func (step DevP2PClientPeering) Description() string {
  return fmt.Sprintf("DevP2PClientPeering: client %d", step.ClientIndex)
}