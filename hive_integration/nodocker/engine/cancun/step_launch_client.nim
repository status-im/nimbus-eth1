import
  ./step

# A step that launches a new client
type LaunchClients struct {
  client.EngineStarter
  ClientCount              uint64
  SkipConnectingToBootnode bool
  SkipAddingToCLMock       bool
}

func (step LaunchClients) GetClientCount() uint64 {
  clientCount = step.ClientCount
  if clientCount == 0 {
    clientCount = 1
  }
  return clientCount
}

func (step LaunchClients) Execute(t *CancunTestContext) error {
  # Launch a new client
  var (
    client client.EngineClient
    err    error
  )
  clientCount = step.GetClientCount()
  for i = uint64(0); i < clientCount; i++ {
    if !step.SkipConnectingToBootnode {
      client, err = step.StartClient(t.T, t.TestContext, t.Genesis, t.ClientParams, t.ClientFiles, t.Engines[0])
    else:
      client, err = step.StartClient(t.T, t.TestContext, t.Genesis, t.ClientParams, t.ClientFiles)
    }
    if err != nil {
      return err
    }
    t.Engines = append(t.Engines, client)
    t.TestEngines = append(t.TestEngines, test.NewTestEngineClient(t.Env, client))
    if !step.SkipAddingToCLMock {
      env.clMock.AddEngineClient(client)
    }
  }
  return nil
}

func (step LaunchClients) Description() string {
  return fmt.Sprintf("Launch %d new engine client(s)", step.GetClientCount())
}
