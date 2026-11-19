# Cloud Native Coverity Helm chart, with renewing internal certificates

Black Duck's Cloud Native Coverity chart (`cnc`) as published, with three changes on top, until the product ships them
itself:

1. **The internal certificates renew.** Charts up to 2026.9.1 made the eight mTLS certificates between Connect and the
   scan services once, valid 365 days, and never renewed them: a year after the install scans failed (COVERITY-588).
   Now the chart renews them before they end (built in, or with cert-manager, or the customer's own), keeps a
   long-lived CA, rotates it with an overlap, restarts what uses a renewed certificate, and reports how long each has
   left. Installations made by an older chart are taken over at the first upgrade, already-ended certificates included.
   See `cnc/CERTIFICATES.md`.
2. **Large downloads work for slow clients.** The TLS sidecar in front of Connect streams responses
   (`cim.cimweb.tlsSidecar.nginxConfig.proxy_buffering: "off"`); before, downloads over about 1.1 GB failed.
3. **Gateway API route timeouts and Tomcat's connection timeout are values** (`cim.gateway.timeouts`,
   `cim.cimweb.tomcat.connectionTimeout`). Envoy Gateway's 15-second default route timeout cut long downloads.

Everything else is the vendor's chart, unchanged.

## Branches

- `vendor`: the vendor's chart, one commit per published version, exactly as downloaded
  (`https://repo.blackduck.com/cloudnative/cnc-<version>.tgz`; the commit message gives its sha256).
- `master`: the patched chart of the latest vendor version. `git diff vendor master -- cnc` is the whole change. It
  only moves forward: each new version's line is merged into it, the earlier versions' history kept.
- Tags: `vendor/cnc-<version>` on each vendor commit, and `patched/cnc-<version>` on our commits on top of it, one per
  change, also for an installation still on an older version. One patch per change:
  `git format-patch vendor/cnc-<version>..patched/cnc-<version> -- cnc`.

## Installing

```bash
helm package cnc                      # cnc-<version>.tgz
helm upgrade --install cnc ./cnc-<version>.tgz -n coverity -f your-values.yaml --wait --timeout 25m
```

The same values as the vendor's chart work unchanged; the new ones (`global.certificates`, and the two above) have
working defaults. An upgrade from the vendor's chart of the same version takes over the existing certificates: Connect
restarts once (about two minutes), the scan services roll without a gap.
