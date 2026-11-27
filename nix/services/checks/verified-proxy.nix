{ self, pkgs, ... }:

let
  mockExecutionApi = pkgs.writeText "mock-execution-api.py" ''
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    import json

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            response = json.dumps({
                "jsonrpc": "2.0",
                "id": request.get("id"),
                "result": "0x1",
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)

        def log_message(self, format, *args):
            pass

    ThreadingHTTPServer(("127.0.0.1", 18545), Handler).serve_forever()
  '';
in

pkgs.testers.runNixOSTest {
  name = "nimbus-verified-proxy-check";

  nodes.machine = {
    imports = [ self.nixosModules.verified-proxy ];

    systemd.services.mock-execution-api = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${mockExecutionApi}";
    };
    systemd.services.nimbus-verified-proxy.after = [ "mock-execution-api.service" ];

    services.nimbus-verified-proxy = {
      enable = true;
      settings = {
        trusted-block-root = "0x0000000000000000000000000000000000000000000000000000000000000000";
        execution-api-url = [ "http://127.0.0.1:18545" ];
        beacon-api-url = [ "http://127.0.0.1:18547" ];
        listen-url = [ "http://127.0.0.1:18546" ];
      };
    };
  };

  testScript = ''
    import json

    machine.wait_for_unit("mock-execution-api.service")
    machine.wait_for_unit("nimbus-verified-proxy.service")
    machine.wait_for_open_port(18546)

    payload = '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
    response = machine.succeed(
        "curl -fsS localhost:18546 -H 'Content-Type: application/json' "
        f"--data '{payload}'"
    )
    data = json.loads(response)
    assert data["result"] == "0x1", f"unexpected proxy response: {data}"
  '';
}
