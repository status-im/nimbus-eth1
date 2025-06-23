# uTP testing infrastructure

Testing infrastructure which allows to test the uTP implementation over different
network conditions on a local machine.

Uses following external tool developed to test the QUIC protocol:

- [quic-network-simulator](https://github.com/marten-seemann/quic-network-simulator)

## Prerequisities

- Machine with Docker installed
- nimbus-eth1 repository set-up to run `make utp_test`

## How it works

Test setup uses Docker Compose to start 3 Docker containers:
- uTP client - which is an instance of the `utp_test_app`
- uTP server - which is an instance of the `utp_test_app`
- sim - which is an instance of the ns3 network simulator with several pre-compiled scenarios

The networking is set up in such way that network traffic is routed from client to server
and server to client through the simulator.
The simulator decides what to do with packets passing through based on the selected scenarios.

Explanation from [quic-network-simulator](https://github.com/marten-seemann/quic-network-simulator):

> The framework uses two networks on the host machine: `leftnet` (IPv4
193.167.0.0/24, IPv6 fd00:cafe:cafe:0::/64) and `rightnet` (IPv4
193.167.100.0/24, IPv6 fd00:cafe:cafe:100::/64). `leftnet` is connected to the
client docker image, and `rightnet` is connected to the server. The ns-3
simulation sits in the middle and forwards packets between `leftnet` and
`rightnet`

Both the uTP client and uTP server have a JSON-RPC API exposed. The `utp_test` application will use these interfaces to initiate transfers between client and server and to verify their outcome.

## How to run

To run integration testing scenarios with different network conditions:

Build the client/server Docker image:

```sh
cd nimbus-eth1/
docker build -t test-utp --build-arg BRANCH_NAME={branch-name} portal/tools/utp_testing/docker
```

Next run the Docker Compose with selected scenario details:

```sh
SCENARIO="scenario_details" docker-compose -f portal/tools/utp_testing/docker/docker-compose.yml up
```

For example, for the `drop-rate` scenario with specified delay, bandwith, and different drop rate values:

```sh
SCENARIO="drop-rate --delay=15ms --bandwidth=10Mbps --queue=25 --rate_to_client=10 --rate_to_server=10" docker-compose -f portal/tools/utp_testing/docker/docker-compose.yml up
```

Then build & run the application that will execute the tests:
```
make utp-test
```

All scenarios are specified in: [scenarios](https://github.com/marten-seemann/quic-network-simulator/tree/master/sim/scenarios)
