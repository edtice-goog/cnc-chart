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
- `cnc-<version>`: our commits on top of that vendor version (`vendor/cnc-<version>`), one per change, for an
  installation on that version. `git format-patch vendor/cnc-<version>..cnc-<version> -- cnc` gives one patch per
  change. A new change is a commit on each version's branch that needs it.
- `master`: the latest version's branch, merged in. `git diff vendor master -- cnc` is the whole change.
- Every branch only moves forward. A new vendor version: its commit on `vendor`, then `cnc-<new>` made from
  `cnc-<old>` with `git rebase --onto vendor/cnc-<new> vendor/cnc-<old>`, then on a detached `cnc-<new>`,
  `git merge -s ours master` pushed as `master`.
- Tags: `vendor/cnc-<version>` on each vendor commit; `patched/cnc-<version>` where that version's patches were first
  published.

## Installing

```bash
helm package cnc                      # cnc-<version>.tgz
helm upgrade --install cnc ./cnc-<version>.tgz -n coverity -f your-values.yaml --wait --timeout 25m
```

The same values as the vendor's chart work unchanged; the new ones (`global.certificates`, and the two above) have
working defaults. An upgrade from the vendor's chart of the same version takes over the existing certificates: Connect
restarts once (about two minutes), the scan services roll without a gap.
