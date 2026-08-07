{ self, pkgs, ... }:

pkgs.testers.runNixOSTest {
  name = "nimbus-execution-client-check";

  nodes.machine = {
    imports = [ self.nixosModules.execution-client ];

    services.nimbus-execution-client = {
      enable = true;
      settings = {
        engine-api = true;
        metrics = true;
        rpc = true;
        ws = true;
      };
    };
  };

  testScript = { nodes, ... }: with nodes.machine.services.nimbus-execution-client.settings; ''
    import json

    machine.wait_for_unit("nimbus-execution-client.service")

    # Port checks
    machine.wait_for_open_port(${toString engine-api-port})
    machine.wait_for_open_port(${toString http-port})
    machine.wait_for_open_port(${toString metrics-port})
    machine.wait_for_open_port(${toString tcp-port})
    machine.wait_for_open_port(${toString udp-port})

    # API checks
    machine.succeed("curl -fsS localhost:${toString http-port}/")
    machine.succeed("curl -fsS localhost:${toString metrics-port}/metrics | grep -E '^nec_execution_head'")

    # Syncing check
    payload = '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
    resp = machine.succeed(f"curl localhost:${toString http-port} -fsS -H 'Content-Type: application/json' --data '{payload}'")
    data = json.loads(resp)
    assert int(data["result"], 16) >= 0, f"no result found in RPC response: {data}"
  '';
}
