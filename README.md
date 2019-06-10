<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2019 Joyent, Inc.
-->

# triton-grafana

The Triton core grafana service. Triton uses
[Prometheus](https://github.com/joyent/triton-prometheus) and
Grafana to track its own metrics and monitor itself, as well as Manta. All
metrics are gathered via [CMON](https://github.com/joyent/triton-cmon).

Note: This repository is part of the Joyent Triton project. See the [contribution
guidelines](https://github.com/joyent/triton/blob/master/CONTRIBUTING.md) --
*Triton does not use GitHub PRs* -- and general documentation at the main
[Triton project](https://github.com/joyent/triton) page.

## Status

Joyent is actively developing Prometheus and Grafana services for use in Triton
and Manta. [RFD 150](https://github.com/joyent/rfd/tree/master/rfd/0150)
describes the current plan and status.

## Setup

Grafana requires either a Triton or Manta Prometheus instance to exist, and will
also function with both simultaneously. Ensure that
[Prometheus](https://github.com/joyent/triton-prometheus) is set up in your
Triton and/or Manta deployment -- see the triton-prometheus README for
Prometheus deployment instructions.

Then, run the following from your Triton headnode's global zone:

    sdcadm post-setup grafana [OPTIONS]

This command will automatically detect whether Manta is deployed and give
the Grafana zone the necessary "manta" nic if so. If Manta is deployed after a
Grafana zone already exists, re-running the above `sdcadm` command will give
the Grafana zone the "manta" nic in an idempotent fashion.

## Architecture

This image runs four services of note:
- An Nginx server performs TLS termination. It runs as the "nginx" SMF service.

- A Node.js proxy server sits between Nginx and Grafana and authenticates users
against the datacenter's UFDS instance. This proxy runs as the "graf-proxy"
SMF service.

- A Grafana instance runs the "grafana" SMF service.

- A BIND server runs on localhost and forwards DNS lookups to the Triton and
Manta [binder](https://github.com/joyent/binder) resolvers.

### Nginx

The Nginx instance is compiled to provide support for the
`ngx_http_auth_request` module, which is necessary to support authentication
subrequests. Nginx issues authentication subrequests using HTTP basic auth to
graf-proxy.

The Nginx instance uses a self-signed certificate by default. The certificate
and key are stored under `/data/grafana/tls`. Operators can manually replace
the certificate with a properly signed certificate -- the certificate lives
on a delegated dataset to persist across reprovisions.

The Nginx config file is generate from a template that lives in the `etc`
directory.

### graf-proxy

The graf-proxy performs authentication against the Triton deployment's
[UFDS](https://github.com/joyent/sdc-ufds) instance. Upon successful
authentication via HTTP basic auth, graf-proxy sets triton-grafana-specific HTTP
headers in its response to Nginx. Nginx then forwards authenticated requests to
the Grafana instance.

The graf-proxy config file is generated from a SAPI template, because it depends
on UFDS-related SAPI values.

#### Security

The graf-proxy restricts access to UFDS operators only. It respects UFDS
lockouts, with the caveat that client-side caching in the `node-ufds` library
may delay the presentation of lockout status to the user, though the UFDS
server is returning a lockout response.

### Grafana

The grafana instance is configured to accept proxy authentication via the HTTP
headers set by graf-proxy -- see the documentation
[here](http://docs.grafana.org/auth/auth-proxy/). In this way, users are able to
authenticate to Grafana using their UFDS credentials.

If a user's Grafana account does not yet exist upon receipt of an authenticated
login request, Grafana will automatically create it. The created Grafana user
will have full admin privileges by default. If a UFDS account is disabled, the
associated Grafana account will remain, but the affected user will not be able
to log in because authentication is always performed against UFDS before
forwarding requests to Grafana.

Grafana's persistent data is stored on a delegated dataset, to ensure that it
persists across reprovisions of the zone.

This image comes pre-configured with a set of standard Triton dashboards. These
dashboards can be edited on the fly, but edits cannot be saved. Users are free
to create their own dashboards, which are fully editable and will persist
across reprovisions.

The grafana config files, with the exception of `triton-datasources.yaml`, are
generated from templates that live in the `etc` directory.
`triton-datasources.yaml` is generated from a SAPI template, because it depends
on values from SAPI.

### BIND

Grafana is currently the only Triton service that must perform resolution of
Manta DNS names -- specifically, the DNS names of the Manta Prometheus
instances. Thus, Grafana must know the IP addresses of the Manta
[binder](https://github.com/joyent/binder) resolvers. It is not sufficient to
place these resolvers in `/etc/resolv.conf`, because there could be an
arbitrary number of binder instances across Triton and Manta.

Thus, the Grafana zone runs a BIND server that forwards DNS requests to the
Triton and Manta binder resolvers as appropriate. The BIND server runs on
localhost, and localhost is the only entry in `/etc/resolv.conf`.

Any changes in the set of Manta resolvers cannot be detected by
[config-agent](https://github.com/joyent/sdc-config-agent), because Grafana
is not deployed under the "manta"
[SAPI](https://github.com/joyent/sdc-sapi) application. However, Grafana can
still query SAPI for the set of Manta resolvers.

This image thus runs a cron job, `bin/update-named.sh`, that checks for changes
in the set of Triton and Manta resolvers and updates the BIND configuration if
changes are found. To avoid the expense of querying SAPI unnecessarily, if the
zone already knows about at least one Manta resolver, it will query the resolver
itself for the new set of resolvers before falling back to querying SAPI.

## Troubleshooting

### Grafana doesn't display Prometheus data

- Is Prometheus reachable? Go to https://\<grafana url\>/datasources, select the
  relevant datasource, and click "Save & Test" at the bottom of the page

- Is BIND running? `svcs bind`

- Are the Prometheus instances healthy and scraping data properly?

- Is `/etc/resolv.conf` correct? It should have `127.0.0.1` as its only
  nameserver entry.

- Are there visible warnings or errors on the grafana webpage?

- Does the Grafana log show errors? `tail $(svcs -L grafana)`

### Grafana is unreachable

- Is Grafana running? `svcs grafana`

- Is `graf-proxy` running? `svcs graf-proxy`

- Is Nginx running? `svcs nginx`

## Testing

There exists a small system test suite for `graf-proxy`. It is driven by the
`test/runtests` script. These tests are designed for a fully deployed Grafana
instance. They are non-destructive, but they create temporary users in UFDS and
thus should not be run in production.
