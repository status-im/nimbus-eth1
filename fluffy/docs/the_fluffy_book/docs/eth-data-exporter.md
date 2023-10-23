# Exporting Ethereum content for Portal

## eth_data_exporter

The `eth_data_exporter` is a tool to extract content from Ethereum EL or CL and
prepare it as Portal content and content keys.

The `eth_data_exporter` can export data for different Portal networks.
Currently the `history` and the `beacon` networks are supported.

Example commands:

```bash
# Build the tool
make eth_data_exporter
# See the different commands and options
./build/eth_data_exporter --help
```

```bash
# Request of `BeaconLightClientUpdate`s and export into the Portal
# network supported format
./build/eth_data_exporter beacon exportLCUpdates --rest-url:http://testing.mainnet.beacon-api.nimbus.team --start-period:816 --count:4
```
