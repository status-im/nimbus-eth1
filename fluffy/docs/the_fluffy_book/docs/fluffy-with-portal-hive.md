# Fluffy with Portal-hive

Fluffy is one of the Portal clients that is being tested with [portal-hive](https://github.com/ethereum/portal-hive).

To see the status of the tests for the current version you can access [https://portal-hive.ethdevops.io/](https://portal-hive.ethdevops.io/).

## Run the hive tests locally

Build portal-hive:

```sh
git clone https://github.com/ethereum/portal-hive.git
cd ./portal-hive
go build .
```

Example commands for running test suites:

```sh
# Run the rpc-compat tests with the 3 different clients
./hive --sim rpc-compat --client fluffy,trin,ultralight

# Run the portal-interop tests with only the fluffy client
./hive --sim portal-interop --client fluffy

# Access results through web-ui:
```sh
go build ./cmd/hiveview
./hiveview --serve --logdir ./workspace/logs
```

!!! note
    You can see all the implemented simulators in [https://github.com/ethereum/portal-hive/tree/main/simulators](https://github.com/ethereum/portal-hive/tree/main/simulators)

## Build a local development Docker image for portal-hive

To debug & develop Fluffy code against portal-hive tests you might want to
create a local development docker image for Fluffy.

To do that follow next steps:

1) Clone and build portal-hive, see above.

2) Build the local development Docker image using the following command:
```
docker build --tag fluffy-dev --file ./fluffy/tools/docker/Dockerfile.portalhive .
```

3) Modify the `FROM` tag in the portal-hive `Dockerfile` of fluffy at
`portal-hive/clients/fluffy/Dockerfile` to use the image that was buid in step 2.

4) Run the tests as [usually](fluffy-with-portal-hive.md/#run-the-hive-tests-locally).

!!! warning
    The `./vendors` dir is dockerignored and cached. If you have to make local
    changes to one of the dependencies in that directory you will have to remove
    `vendors/` from `./fluffy/tools/docker/Dockerfile.portalhive.dockerignore`.

