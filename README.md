# triton-grafana

The Triton core grafana service. Triton is moving to using
[prometheus](https://github.com/joyent/triton-prometheus) and
grafana to track its own metrics and to provide an option for monitoring Triton
itself. All Triton metrics are gathered via
[CMON](https://github.com/joyent/triton-cmon).


## Status

The Triton core prometheus and grafana services are currently being actively
developed. [RFD 150](https://github.com/joyent/rfd/tree/master/rfd/0150)
describes the current plan and status.


## Setup

First ensure that [prometheus](https://github.com/joyent/triton-prometheus) is
set up in your TritonDC, typically via:

    sdcadm post-setup prometheus [OPTIONS]

Then run the following from your TritonDC's headnode global zone:

    sdcadm post-setup grafana [OPTIONS]


## Configuration

Primarily this VM runs a Grafana instance (as the "grafana" SMF service).
The config files for that service are as follows. Note that "/data/..." is a
delegate dataset to persist through reprovisions.

    /data/grafana/conf/*                # configuration files
    /data/grafana/data/*                # grafana database (users, dashboards,
                                        # etc.)
    /data/grafana/password.txt          # Grafana password
    /data/tls/*                         # TLS certs

Like most Triton core VM services, a config-agent is used to gather some
config data.


## Dashboards

This repo also holds JSON files of common Grafana dashboards for monitoring
Triton with a Prometheus/Grafana setup. These are stored under `dashboards`.

### Links

- Triton service-specific metrics typically use
  [node-triton-metrics](https://github.com/joyent/node-triton-metrics), so look
  for some commonality there.


## Security

Grafana listens on the admin network only. The default user is "admin" and the
password is in the /data directory. TODO switch to ufds auth


## Troubleshooting

### Grafana doesn't display Triton data

Triton's Grafana gets its data from Prometheus. Here are some things to check
if this appears to be failing:

- Is Grafana running? `svcs grafana`

- Is Prometheus scraping data properly?

- Is Prometheus reachable? Go to https://<grafana url>/datasources, select the
  "Triton" datasource, and click "Save & Test" at the bottom of the page

- Are there visible warnings or errors on the grafana webpage?

- Does the Grafana config (the files under /data/grafana/conf) look correct?

- Does the Grafana log show errors? `tail $(svcs -L grafana)`
