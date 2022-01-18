# uTP testing infrastrucure 

Testing infrastrucure which enables to test uTP implementation over different
network conditions on local machine.

Highly based on tools developed to test quic protocol:

[quic-interop-runner](https://github.com/marten-seemann/quic-interop-runner)

[quic-netowork-simulator](https://github.com/marten-seemann/quic-network-simulator)

## Prerequisities

- Machine with docker installed

- nimbus-eth1 toolchain to run utp_test.nim

## Practicalities

For now process is semi-manual (TODO automate this as much as possible)

To run integration testing scenarios with different network conditions

```
1. cd nimbus-eth1/
2. docker build -t test-utp --build-arg BRANCH_NAME={branch-name} fluffy/tools/utp_testing/docker
3. SCENARIO="scenario_details" docker-compose -f fluffy/tools/utp_testing/docker/docker-compose.yml up

For example:
SCENARIO="drop-rate --delay=15ms --bandwidth=10Mbps --queue=25 --rate_to_client=0 --rate_to_server=0" docker-compose -f fluffy/tools/utp_testing/docker/docker-compose.yml up
would start `drop-rate` scenario with specified delay, bandwith, and different drop rates
4. make utp-test
```

All scenarios are specified in: [scenarios](https://github.com/marten-seemann/quic-network-simulator/tree/master/sim/scenarios)
