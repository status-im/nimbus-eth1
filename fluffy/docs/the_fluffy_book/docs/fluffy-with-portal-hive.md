# Fluffy with Portal-hive

Fluffy is one of the Portal clients that is being tested with [hive](https://github.com/ethereum/hive).

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
# Run the portal hive tests with only the fluffy client
./hive --sim portal --client fluffy

# Run the portal hive tests with different clients
./hive --sim portal --client fluffy,trin,ultralight,shisui

# Run portal hive tests from a specific portal hive simulator
./hive --sim portal --client fluffy --sim.limit history-interop

# Access results through web-ui:
```sh
go build ./cmd/hiveview
./hiveview --serve --logdir ./workspace/logs
```

!!! note
    You can see all the implemented Portal simulators in [https://github.com/ethereum/hive/blob/master/simulators/portal/](https://github.com/ethereum/hive/blob/master/simulators/portal/)

## Build a local development Docker image for portal-hive

To debug & develop Fluffy code against hive tests you might want to
create a local development Docker image for Fluffy.

To do that follow next steps:

1) Clone and build hive, see above.

2) Build the local development Docker image using the following command:
```
docker build --tag fluffy-dev --file ./fluffy/tools/docker/Dockerfile.debug .
```

3) Modify the `FROM` tag in the portal-hive `Dockerfile` of fluffy at
`./hive/clients/fluffy/Dockerfile` to use the image that was build in step 2.

4) Run the tests as [usually](fluffy-with-portal-hive.md/#run-the-hive-tests-locally).

!!! warning
    The `./vendors` dir is dockerignored and cached. If you have to make local
    changes to one of the dependencies in that directory you will have to remove
    `vendors/` from `./fluffy/tools/docker/Dockerfile.debug.dockerignore`.

!!! note
    When developing on Linux the `./fluffy/tools/docker/Dockerfile.debug.linux` Dockerfile can also be used instead. It does require to manually build fluffy first as it copies over this binary.
