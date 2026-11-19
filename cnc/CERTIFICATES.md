# Internal certificates

Connect and the scan services talk to each other over mutual TLS. Their certificates are eight Kubernetes Secrets in
the release's namespace. They have nothing to do with the ingress certificate that browsers and clients see.

| Secret | CN | Signed by | Used by |
|---|---|---|---|
| `<release>-ca-x509` | CNC Certificate Authority | itself | signs the next six; mounted by nothing |
| `<release>-cim-x509` | cim | the CA | `cim` (the TLS sidecar's server certificate, and Connect's client certificate) |
| `<release>-cs-x509` | cim | the CA | `commit-server` (only with several Connect replicas or pgpool) |
| `<release>-cache-service-x509` | cache-service | the CA | `cache-service` |
| `<release>-storage-service-x509` | storage-service | the CA | `storage-service` |
| `<release>-storage-proxy-service-x509` | storage-proxy-service | the CA | the analysis jobs |
| `<release>-scan-service-x509` | scan-service | the CA (it is a CA too) | `scan-service` |
| `<release>-admin-x509` | admin | scan-service | the analysis jobs |

Each holds `tls.crt`, `tls.key` and `ca.crt` (the CAs the service trusts). Every service reads them only when it starts.

Charts up to 2026.9.0 made them once, valid 365 days, and never renewed them: a year after the first install the CA and
every certificate ended at the same moment and scans failed (COVERITY-588). This chart renews them, and so it also
takes over Secrets an older chart made.

## The modes: `global.certificates.mode`

| | `builtIn` (default) | `certManager` | `external` |
|---|---|---|---|
| Who issues | the chart's certificate keeper | cert-manager, from the chart's Issuers and Certificates | you |
| Renewal | `renewBefore` ahead of the end, on `schedule` and at every install/upgrade | cert-manager, `renewBefore` ahead | you, before the end |
| CA | long-lived; rotated with an overlap `ca.renewBefore` ahead, or when `ca.rotation` gets a new value | long-lived, renewed with the same key | yours |
| Needs | nothing | cert-manager (`cert-manager.io/v1`) | the Secrets before the install |
| Restarts and the report | the keeper | the keeper | the keeper |

In every mode the **certificate keeper** runs:
- before every install and upgrade (Job `<release>-certificates-pre`): in `builtIn` it issues and renews; in
  `certManager` it prepares Secrets an older chart made; in `external` it stops the install if a Secret is missing,
  incomplete or ended;
- after every install and upgrade (Job `<release>-certificates-post`) and on `schedule` (CronJob
  `<release>-certificates`): it restarts each Deployment whose certificates changed since its pods started, and
  reports.

## Values

All under `global.certificates`. Durations are Go durations: `8760h` is a year, `720h` 30 days, `10m` ten minutes.

| Value | Default | Meaning |
|---|---|---|
| `mode` | `builtIn` | `builtIn`, `certManager` or `external` (above) |
| `duration` | `8760h` | lifetime of the service certificates (all but the CA). cert-manager needs at least `1h` |
| `renewBefore` | `720h` | renew this long before the end. Shorter than `duration`; cert-manager needs at least `5m` |
| `ca.duration` | `87600h` | lifetime of the CA |
| `ca.renewBefore` | `17520h` | start a CA rotation (`builtIn`) or renewal (`certManager`) this long before the CA ends. Longer than `duration`, shorter than `ca.duration` |
| `ca.rotation` | `""` | `builtIn`: set it to a new value to rotate the CA now, for example after its key leaked (removing it starts nothing) |
| `privateKey.size` | `2048` | RSA key size of new keys: 2048, 3072 or 4096. Existing certificates get it at their next renewal (`builtIn` re-issues at once when it changes) |
| `privateKey.format` | `pkcs1` | the encoding of `tls.key`: `pkcs1` (`RSA PRIVATE KEY`, what older charts wrote) or `pkcs8` |
| `schedule` | `17 3 * * *` | when the keeper's CronJob runs. Renewals and the restarts they need happen then: it is the maintenance window |
| `timeZone` | `""` | the schedule's time zone (`Europe/Berlin`); empty is the cluster's default, usually UTC |
| `restarts.waitForScans` | `true` | a restart waits while an analysis job runs (the next run tries again)... |
| `restarts.forceBefore` | `72h` | ...unless the certificates the running pods hold end within this |
| `restarts.scanJobSelector` | `scanfarm.coverity.com/type=scanfarm-job` | the label selector of the scan service's analysis jobs (what 2026.9.0 puts on them) |
| `image` | `""` | the keeper's image. Empty: the TLS sidecar's nginx image (`cim.cimweb.tlsSidecar`), so nothing new to pull. It needs bash, openssl, curl and GNU coreutils |
| `resources`, `nodeSelector`, `tolerations` | | for the keeper's pods; `tolerations` defaults to `global.tolerations` |
| `podSecurityContext`, `containerSecurityContext` | non-root (uid 5000, as the chart's other pods), read-only root, no capabilities | for the keeper's pods |

The chart refuses an install whose lifetimes don't fit together (for example `renewBefore` not shorter than
`duration`).

## What a renewal does to the services

A renewed certificate is written into its Secret. Kubernetes updates the files in running pods within a minute or so,
but the services read them only at startup, so the keeper restarts each Deployment that uses it:
- `scan-service`, `storage-service` and `cache-service` roll without a gap (a new pod first);
- `cim` (Connect) and `commit-server` are `Recreate`: Connect is unavailable for about two minutes.

The old certificate stays valid until its own end (`renewBefore` later), and the CA doesn't change, so nothing breaks
while a restart waits: for a running scan (`restarts.waitForScans`) or for the next scheduled run. With the defaults
each service restarts once a year, at the scheduled time, 30 days ahead of the end.

A `helm upgrade` that changes nothing renews nothing and restarts nothing.

## nginx updates

The TLS sidecar in front of Connect (`cim.cimweb.tlsSidecar`) is nginx, and so is the image the keeper runs in. The
chart doesn't pin an nginx release: `tlsSidecar.version` is `stable`, nginx's stable branch, from Docker Hub's official
image (`docker.io/library/nginx`), pulled with `Always` (`tlsSidecar.imagePullPolicy`). Every start of the sidecar or of the keeper takes the image the tag names at that
moment, so nginx's fixes arrive without a new chart.

The sidecar starts rarely, though: only when Connect restarts. So at each run (the post hook and the CronJob), the
keeper compares the image its own pod has just pulled with the one each sidecar runs. When a sidecar runs an older
image, the keeper restarts its Deployment, the same way as for a certificate (`cim` and `commit-server` are
`Recreate`: about two minutes). It waits while analysis jobs run (`restarts.waitForScans`). There's no deadline, so a
run that finds a scan leaves the restart to the next run.

| Value (`cim.cimweb.tlsSidecar.`) | Default | What |
|---|---|---|
| `version` | `stable` | the nginx tag. Keep a Debian-based one (not `-alpine`): the keeper needs bash, openssl and curl. A release such as `1.30.7` pins it again |
| `imagePullPolicy` | `Always` | for the sidecar, and for the keeper when it runs in this image. Empty: `imagePullPolicy`, then `global.imagePullPolicy` |
| `restartOnUpdate` | `true` | the keeper's restart for a newer nginx. It's off whenever `imagePullPolicy` isn't `Always` or the keeper has its own `global.certificates.image`, because then its own pull says nothing about the tag |
| `registry`, `image` | `docker.io/library`, `nginx` | where nginx comes from: Docker Hub's official image, which publishes `stable` (Black Duck's registry carries only the release the vendor's chart pinned). `registry` comes before `imageRegistry` and `global.imageRegistry`: an installation that mirrors the chart's images sets it to its mirror (`""` uses `imageRegistry`), and the mirror must keep the tag current |

## The CA rotation (`builtIn`)

A new CA can't take over in one step: services that still trust only the old one would reject certificates from the
new one. So the keeper rotates in three steps, one per run, each waiting for the previous one's restarts:
1. **Trust both.** A new CA is made. Every service gets both CAs in its `ca.crt` and restarts.
2. **Re-issue.** The new CA becomes the active one and every certificate is re-issued from it; the old CA stays trusted.
   The services restart.
3. **Drop the old CA.** `ca.crt` holds only the new CA again; the services restart.

It starts by itself `ca.renewBefore` ahead of the CA's end, or at once when `ca.rotation` gets a new value. The CA Secret holds
the step (`certificates.coverity.blackduck.com/phase`: stable, trust, reissue) and, during a rotation, the next or the
previous CA.

The order of the two CAs in `ca.crt` matters: Connect imports `ca.crt` into its truststore with `keytool`, which takes
only the first certificate of the file. The keeper puts the old CA first in step 1 and the new one first from step 2.

## Upgrading from a chart that made the Secrets itself (2026.9.0 and earlier)

Nothing to do: the first `helm upgrade` takes them over.
- `builtIn`: the CA made by the older chart keeps its key, its subject and its key identifier, and gets the full
  `ca.duration`, so everything it signed stays valid (also for OpenSSL and Java, which match key identifiers). Every
  other certificate is re-issued from it at once. The upgrade's rollout restarts each service once; the keeper's
  post-upgrade run restarts only what the upgrade didn't.
- **Already ended** (scans fail today): the same, and the restarts don't wait for anything. The upgrade is the fix.
- `certManager`: the Secrets are recreated as `kubernetes.io/tls` (the only type cert-manager writes) with the same
  data, and cert-manager re-issues them; the CA keeps its key.
- `external`: the existing Secrets are accepted while they are valid; replace them with yours before they end.

## Going back to an older chart

The older charts' generator recreates a Secret whose names differ from its own, and can't change a Secret's type.
- From `builtIn`: nothing to do. The keeper's certificates carry the generator's own names, so it recreates nothing
  and keeps them until they end (then it renews nothing, as before).
- From `certManager`: cert-manager can't carry the CA's name "CNC Certificate Authority" (not a DNS name), and its
  Secrets are `kubernetes.io/tls`, so the generator would fail on the CA. Delete the eight Secrets just before the
  upgrade; the older chart makes new ones.

## Seeing how long they have left

```bash
kubectl -n <namespace> get configmap <release>-certificates-status -o jsonpath='{.data.report}'
kubectl -n <namespace> logs job/<release>-certificates-post
```

```
SECRET                               CN                         NOT-AFTER             LEFT               STATE
cnc-ca-x509                          CNC Certificate Authority  2036-11-15T23:23:52Z  3650 days          ok, CA phase stable
cnc-cim-x509                         cim                        2027-11-18T23:23:52Z  365 days           ok
...
```

A state other than `ok` is also a `WARNING` line in the keeper's log: `ENDED`, `MISSING`, `UNREADABLE`, or (in
`certManager` and `external` mode) `RENEW-DUE` when a certificate is inside its renewal window and nobody renewed it.
Each Secret the keeper writes carries `certificates.coverity.blackduck.com/not-after`.

## cert-manager

The chart creates, in the release's namespace: a self-signed Issuer for the CA, the CA's Certificate (`rotationPolicy:
Never`, so a renewal keeps its key and everything it signed stays valid), a CA Issuer that signs the six service
certificates, and one for `scan-service`, which signs `admin`. Same Secret names, subjects and SANs as `builtIn`.
cert-manager renews; the keeper restarts. A new CA key (rather than a renewal) is a hard switch in this mode; use
`builtIn` for a rotation with an overlap.

## Bringing your own (`external`)

Create the seven service Secrets (the CA's own Secret is optional) with `tls.crt`, `tls.key` and `ca.crt` before the
install, with the CNs and SANs in the table above (`<release>-<service>` and
`<release>-<service>.<namespace>.svc.cluster.local`), server and client use, and `admin` signed by a `scan-service` CA.
Replace them before they end; the keeper restarts what uses them at its next run, and warns from `renewBefore` ahead.
