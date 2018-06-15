# Triton Metrics Dashboards

A repo holding JSON dumps of common Grafana dashboards for monitoring Triton
Data Center (a.k.a Triton) itself with a prometheus/grafana setup.

The current goal is to have a shared place for possibly useful dashboards
so we can build tooling around preloading a Grafana sourcing from a Prometheus
setup to gather Triton core metrics from CMON.

## Current Status

This is still a greenfield, i.e. no nitpicking on updates here for now.

## Links

- Triton service-specific metrics typically use
  [node-triton-metrics](https://github.com/joyent/node-triton-metrics), so look
  for some commonality there.

