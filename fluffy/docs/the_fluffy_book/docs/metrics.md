# Metrics and their visualisation

In this page we'll cover how to enable metrics and how to use Grafana and
Prometheus to help you visualize these real-time metrics concerning the Fluffy
node.

## Enable metrics in Fluffy

To enable metrics run Fluffy with the `--metrics` flag:
```bash
./build/fluffy --metrics
```
Default the metrics are available at [http://127.0.0.1:8008/metrics](http://127.0.0.1:8008/metrics).

The address can be changed with the `--metrics-address` and `--metrics-port` options.

This provides only a snapshot of the current metrics. In order track the metrics
over time and to also visualise them one can use for example Prometheus and Grafana.

## Visualisation through Prometheus and Grafana

<!-- TODO: Rework this page without linking to nimbus.guide page about metrics -->

The steps on how to set up metrics visualisation with Prometheus and Grafana is
explained in [this guide](https://nimbus.guide/metrics-pretty-pictures.html#prometheus-and-grafana).

A Fluffy specific dashboard can be found [here](https://github.com/status-im/nimbus-eth1/blob/master/fluffy/grafana/fluffy_grafana_dashboard.json).

This is the dashboard used for our Fluffy testnet fleet.
In order to use it locally, you will have to remove the
`{job="nimbus-fluffy-metrics"}` part from the `instance` and `container`
variables queries in the dashboard settings. Or they can also be changed to a
constant value.

The other option would be to remove those variables and remove their usage in
each panel query.
