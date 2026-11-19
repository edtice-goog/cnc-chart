{{/*
The internal certificates (global.certificates). Helpers for keeper.yaml and cert-manager.yaml.
*/}}

{{/* Whether this release uses the internal certificates at all: the same condition as the TLS sidecar. */}}
{{- define "cnc.certificates.enabled" -}}
{{- if or (index .Values "scan-services").enabled .Values.cim.cimweb.tlsSidecar.enabled }}true{{ end }}
{{- end }}

{{- define "cnc.certificates.mode" -}}
{{- $m := (.Values.global.certificates | default dict).mode | default "builtIn" -}}
{{- if not (has $m (list "builtIn" "certManager" "external")) -}}
{{- fail (printf "global.certificates.mode must be builtIn, certManager or external, not %q" $m) -}}
{{- end -}}
{{- $m -}}
{{- end }}

{{/* A Go duration (8760h, 90m, 1h30m, 45s; d for days is accepted too) in seconds. */}}
{{- define "cnc.certificates.seconds" -}}
{{- $s := toString . -}}
{{- if not (regexMatch "^([0-9]+[dhms])+$" $s) -}}
{{- fail (printf "global.certificates: %q is not a duration like 8760h, 90m or 1h30m" $s) -}}
{{- end -}}
{{- $t := 0 -}}
{{- range regexFindAll "[0-9]+[dhms]" $s -1 -}}
{{- $n := int (trimSuffix "d" (trimSuffix "h" (trimSuffix "m" (trimSuffix "s" .)))) -}}
{{- if hasSuffix "d" . }}{{ $t = add $t (mul $n 86400) }}{{ else if hasSuffix "h" . }}{{ $t = add $t (mul $n 3600) }}{{ else if hasSuffix "m" . }}{{ $t = add $t (mul $n 60) }}{{ else }}{{ $t = add $t $n }}{{ end -}}
{{- end -}}
{{- $t -}}
{{- end }}

{{/* Checks the lifetimes once, so a bad value fails the install rather than the keeper. */}}
{{- define "cnc.certificates.validate" -}}
{{- $c := .Values.global.certificates -}}
{{- $d := include "cnc.certificates.seconds" $c.duration | int -}}
{{- $rb := include "cnc.certificates.seconds" $c.renewBefore | int -}}
{{- $cad := include "cnc.certificates.seconds" $c.ca.duration | int -}}
{{- $carb := include "cnc.certificates.seconds" $c.ca.renewBefore | int -}}
{{- if ge $rb $d }}{{ fail "global.certificates.renewBefore must be shorter than global.certificates.duration" }}{{ end -}}
{{- if ge $carb $cad }}{{ fail "global.certificates.ca.renewBefore must be shorter than global.certificates.ca.duration" }}{{ end -}}
{{- if le $carb $d }}{{ fail "global.certificates.ca.renewBefore must be longer than global.certificates.duration, so every certificate is re-issued from a new CA before the old one ends" }}{{ end -}}
{{- if not (has (int $c.privateKey.size) (list 2048 3072 4096)) }}{{ fail "global.certificates.privateKey.size must be 2048, 3072 or 4096" }}{{ end -}}
{{- if eq (include "cnc.certificates.mode" .) "certManager" -}}
{{- if lt $d 3600 }}{{ fail "global.certificates.duration: cert-manager needs at least 1h" }}{{ end -}}
{{- if lt $rb 300 }}{{ fail "global.certificates.renewBefore: cert-manager needs at least 5m" }}{{ end -}}
{{- end -}}
{{- end }}

{{/*
The certificates, one per line: secret|commonName|issuer secret or "self"|kind (ca, subca, leaf)|usages|SANs.
The same names, subjects, SANs and uses as the generator of older charts (cnc-common-infra, read from its Secrets on
a 2026.9.0 install): C=US, O=<zero UUID>, CN as below, PrintableString; the manifest's SANs plus the CN; server and
client use for all eight. So Secrets it made are taken over in place, and its generator, if an older chart runs it
again, finds its own names and recreates nothing (it does recreate a Secret whose names differ). That includes the CA's
"CNC Certificate Authority", not a host name. A sub-CA comes before what it signs.
*/}}
{{- define "cnc.certificates.list" -}}
{{- $f := include "cnc.fullname" . -}}
{{- $ns := .Release.Namespace -}}
{{ $f }}-ca-x509|CNC Certificate Authority|self|ca|server,client|ca,CNC Certificate Authority
{{ $f }}-cache-service-x509|cache-service|{{ $f }}-ca-x509|leaf|server,client|{{ $f }}-cache-service,{{ $f }}-cache-service.{{ $ns }}.svc.cluster.local,cache-service
{{ $f }}-storage-service-x509|storage-service|{{ $f }}-ca-x509|leaf|server,client|{{ $f }}-storage-service,{{ $f }}-storage-service.{{ $ns }}.svc.cluster.local,storage-service
{{ $f }}-storage-proxy-service-x509|storage-proxy-service|{{ $f }}-ca-x509|leaf|server,client|{{ $f }}-storage-proxy-service,{{ $f }}-storage-proxy-service.{{ $ns }}.svc.cluster.local,storage-proxy-service
{{ $f }}-cim-x509|cim|{{ $f }}-ca-x509|leaf|server,client|{{ $f }}-cim,{{ $f }}-cim.{{ $ns }}.svc.cluster.local,cim
{{ $f }}-cs-x509|cim|{{ $f }}-ca-x509|leaf|server,client|{{ $f }}-commit-server,{{ $f }}-commit-server.{{ $ns }}.svc.cluster.local,cim
{{ $f }}-scan-service-x509|scan-service|{{ $f }}-ca-x509|subca|server,client|{{ $f }}-scan-service,{{ $f }}-scan-service.{{ $ns }}.svc.cluster.local,scan-service
{{ $f }}-admin-x509|admin|{{ $f }}-scan-service-x509|leaf|server,client|admin
{{- end }}

{{/*
What each Deployment reads only when it starts: when one of these changes, the keeper restarts the Deployment.
deployment|secret:<name>,configmap:<name>
*/}}
{{- define "cnc.certificates.consumers" -}}
{{- $f := include "cnc.fullname" . -}}
{{ $f }}-cim|secret:{{ $f }}-cim-x509
{{ $f }}-commit-server|secret:{{ $f }}-cs-x509
{{ $f }}-scan-service|secret:{{ $f }}-scan-service-x509,configmap:{{ $f }}-connect-config
{{ $f }}-storage-service|secret:{{ $f }}-storage-service-x509,configmap:{{ $f }}-connect-config
{{ $f }}-cache-service|secret:{{ $f }}-cache-service-x509,configmap:{{ $f }}-connect-config
{{- end }}

{{- define "cnc.certificates.secretNames" -}}
{{- range splitList "\n" (include "cnc.certificates.list" .) }}{{ if . }}{{ (splitList "|" .) | first }}
{{ end }}{{ end -}}
{{- end }}

{{- define "cnc.certificates.image" -}}
{{- $c := .Values.global.certificates -}}
{{- if $c.image }}{{ $c.image }}{{ else }}{{ include "tlsSidecar.image.name" . | trim }}{{ end -}}
{{- end }}

{{/* The keeper's role: its own Secrets and ConfigMaps by name, the consumers' Deployments, pods and jobs to read. */}}
{{- define "cnc.certificates.rules" -}}
{{- $f := include "cnc.fullname" . -}}
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["create"]
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames:
    {{- range splitList "\n" (include "cnc.certificates.secretNames" .) }}{{ if . }}
    - {{ . }}
    {{- end }}{{ end }}
  verbs: ["get", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["create"]
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["{{ $f }}-certificates-status", "{{ $f }}-certificates-lock", "{{ $f }}-connect-config"]
  verbs: ["get", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  resourceNames:
    {{- range splitList "\n" (include "cnc.certificates.consumers" .) }}{{ if . }}
    - {{ (splitList "|" .) | first }}
    {{- end }}{{ end }}
  verbs: ["get", "patch"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["list"]
- apiGroups: ["batch"]
  resources: ["jobs"]
  verbs: ["list"]
{{- end }}

{{/* The keeper's pod. dict: ctx, run (pre, post, cron), sa, cm */}}
{{- define "cnc.certificates.pod" -}}
{{- $ := .ctx -}}
{{- $c := $.Values.global.certificates -}}
serviceAccountName: {{ .sa }}
automountServiceAccountToken: true
restartPolicy: Never
{{- if or $.Values.imagePullSecret $.Values.global.imagePullSecret }}
imagePullSecrets:
  - name: {{ $.Values.imagePullSecret | default $.Values.global.imagePullSecret }}
{{- end }}
securityContext:
  {{- toYaml ($c.podSecurityContext | default (dict "runAsNonRoot" true "runAsUser" 5000 "runAsGroup" 5000 "seccompProfile" (dict "type" "RuntimeDefault"))) | nindent 2 }}
{{- with $c.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $c.tolerations | default $.Values.tolerations | default $.Values.global.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
containers:
  - name: keeper
    image: {{ include "cnc.certificates.image" $ }}
    imagePullPolicy: {{ $.Values.imagePullPolicy | default $.Values.global.imagePullPolicy }}
    command: ["/bin/bash", "/etc/cnc-certificates/keeper.sh"]
    env:
      - name: MODE
        value: {{ include "cnc.certificates.mode" $ | quote }}
      - name: RUN
        value: {{ .run | quote }}
      - name: RELEASE
        value: {{ include "cnc.fullname" $ | quote }}
      - name: NAMESPACE
        valueFrom:
          fieldRef:
            fieldPath: metadata.namespace
      - name: DURATION
        value: {{ $c.duration | quote }}
      - name: RENEW_BEFORE
        value: {{ $c.renewBefore | quote }}
      - name: CA_DURATION
        value: {{ $c.ca.duration | quote }}
      - name: CA_RENEW_BEFORE
        value: {{ $c.ca.renewBefore | quote }}
      - name: CA_ROTATION
        value: {{ $c.ca.rotation | default "" | quote }}
      - name: KEY_SIZE
        value: {{ $c.privateKey.size | quote }}
      - name: KEY_FORMAT
        value: {{ $c.privateKey.format | default "pkcs1" | quote }}
      - name: WAIT_FOR_SCANS
        value: {{ $c.restarts.waitForScans | quote }}
      - name: FORCE_BEFORE
        value: {{ $c.restarts.forceBefore | quote }}
      - name: SCAN_JOB_SELECTOR
        value: {{ $c.restarts.scanJobSelector | default "" | quote }}
    resources:
      {{- toYaml $c.resources | nindent 6 }}
    securityContext:
      {{- toYaml ($c.containerSecurityContext | default (dict "allowPrivilegeEscalation" false "readOnlyRootFilesystem" true "capabilities" (dict "drop" (list "ALL")))) | nindent 6 }}
    volumeMounts:
      - name: keeper
        mountPath: /etc/cnc-certificates
        readOnly: true
      - name: tmp
        mountPath: /tmp
volumes:
  - name: keeper
    configMap:
      name: {{ .cm }}
      defaultMode: 0444
  - name: tmp
    emptyDir:
      sizeLimit: 64Mi
{{- end }}

{{/* The keeper's ConfigMap data: the script and what it works on. */}}
{{- define "cnc.certificates.configData" -}}
keeper.sh: |
{{ .Files.Get "files/certificates/keeper.sh" | indent 2 }}
certificates.txt: |
{{ include "cnc.certificates.list" . | indent 2 }}
consumers.txt: |
{{ include "cnc.certificates.consumers" . | indent 2 }}
{{- end }}
