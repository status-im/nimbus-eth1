# Testing Nimbus Portal client with hive

The `nimbus_portal_client` is one of the Portal clients that is being tested with [hive](https://github.com/ethereum/hive).

To see the status of the tests for the current version you can access [https://portal-hive.ethdevops.io/](https://portal-hive.ethdevops.io/).

## Run the hive tests locally

Build hive:

```sh
git clone https://github.com/ethereum/hive.git
cd ./hive
go build .
```

Example commands for running test suites:

```sh
# Run the portal hive tests with only the Nimbus Portal client
./hive --sim portal --client nimbus-portal

# Run the portal hive tests with different clients
./hive --sim portal --client nimbus-portal,trin,ultralight,shisui

# Run portal hive tests from a specific portal hive simulator
./hive --sim portal --client nimbus-portal --sim.limit history-interop
```

Access the results through web-ui:

```sh
go build ./cmd/hiveview
./hiveview --serve --logdir ./workspace/logs
```

!!! note
    You can see all the implemented Portal simulators in [https://github.com/ethereum/hive/blob/master/simulators/portal/](https://github.com/ethereum/hive/blob/master/simulators/portal/)

## Build a local development Docker image for hive

To debug & develop the Nimbus Portal client code against hive tests you might want to
create a local development Docker image.

To do that follow next steps:

1) Clone and build hive, see above.

2) Build the local development Docker image using the following command:
```
docker build --tag nimbus-portal-dev --file ./portal/docker/Dockerfile.debug .
```

3) Modify the `FROM` tag in the portal-hive `Dockerfile` of Nimbus Portal client at
`./hive/clients/nimbus-portal/Dockerfile` to use the image that was build in step 2.

4) Run the tests as [usual](nimbus-portal-with-portal-hive.md/#run-the-hive-tests-locally).

!!! warning
    The `./vendors` dir is dockerignored and cached. If you have to make local
    changes to one of the dependencies in that directory you will have to remove
    `vendors/` from `./portal/docker/Dockerfile.debug.dockerignore`.

!!! note
    When developing on Linux the `./portal/docker/Dockerfile.debug.linux` Dockerfile can also be used instead. It does require to manually build `nimbus_portal_client` first as it copies over this binary.
