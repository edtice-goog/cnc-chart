{{/* vim: set filetype=mustache: */}}
{{/* Expand the name of the chart. */}}
{{- define "cnc.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name. */}}
{{- define "cnc.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Create chart name and version as used by the chart label. */}}
{{- define "cnc.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels */}}
{{- define "chart.labels" -}}
app.kubernetes.io/name: {{ include "cnc.name" . }}
helm.sh/chart: {{ include "cnc.chart" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: "{{ include "cnc.app-version" . }}"
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
chart: {{ .Chart.Name | quote }}
{{- end -}}

{{- define "service.labels" -}}
helm.sh/chart: {{ include "cnc.chart" . }}
{{ include "service.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: "{{ include "cnc.app-version" . }}"
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "service.selectorLabels" -}}
app.kubernetes.io/name: {{ .serviceName }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ .serviceName }}
app.kubernetes.io/part-of: coverity
{{- end }}

{{- define "cim.common.selectorLabels" -}}
app.kubernetes.io/name: {{ .serviceName }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: cim
app.kubernetes.io/part-of: coverity
{{- end }}

{{- define "jgroups.service.selectorLabels" -}}
app.kubernetes.io/component: cim
{{- end }}

{{- define "jgroups.service.url" -}}
- name: JGROUPS_DNS_QUERY
  value: {{ include "cnc.fullname" . }}-cim-jgroups-svc.{{ .Release.Namespace }}.svc.cluster.local
{{- end }}

{{- define "cnc.app-version" -}}
{{- printf "%s" .Chart.AppVersion | replace "+" "_" | replace ":" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
https://github.com/openstack/openstack-helm-infra/blob/master/helm-toolkit/templates/utils/_joinListWithComma.tpl
*/}}
{{- define "helm-toolkit.utils.joinListWithComma" -}}
{{- $local := dict "first" true -}}
{{- range $k, $v := . -}}{{- if not $local.first -}},{{- end -}}{{- $v -}}{{- $_ := set $local "first" false -}}{{- end -}}
{{- end -}}


{{- define "cnc.postgres.secret" }}
{{- if not (or .Values.global.postgres.existingSecret (index .Values .serviceName).postgres.existingSecret) }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "cnc.fullname" . }}-{{ .serviceName }}-db-creds
  namespace: {{ .Release.Namespace }}
  annotations:
    helm.sh/hook-weight: "-14"
    helm.sh/hook: pre-upgrade, pre-install
type: Opaque
stringData:
  host: {{ required "A valid postgres host entry is required." ((index .Values .serviceName).postgres.host | default .Values.global.postgres.host) | quote }}
  port: {{ required "A valid postgres port entry is required." ((index .Values .serviceName).postgres.port | default .Values.global.postgres.port)| quote }}
  username: {{ required "A valid postgres username entry is required." ((index .Values .serviceName).postgres.user | default .Values.global.postgres.user) | quote }}
  password: {{ required "A valid postgres password entry is required." ((index .Values .serviceName).postgres.password | default .Values.global.postgres.password) | quote }}
{{- end }}
{{- end }}

{{- define "cnc.postgres.jdbcurl" -}}
jdbc:postgresql://${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DATABASE}?sslmode=${POSTGRES_SSLMODE}&sslfactory=org.postgresql.ssl.DefaultJavaSSLFactory
{{- end -}}

{{- define "postgres.common.environment" }}
{{- if or .Values.global.postgres.existingSecret (index .Values .serviceName).postgres.existingSecret }}
- name: POSTGRES_HOST
  valueFrom:
    secretKeyRef:
      name: {{ (index .Values .serviceName).postgres.existingSecret | default .Values.global.postgres.existingSecret | quote }}
      key: "host"
- name: POSTGRES_PORT
  valueFrom:
    secretKeyRef:
      name: {{ (index .Values .serviceName).postgres.existingSecret | default .Values.global.postgres.existingSecret | quote }}
      key: "port"
- name: POSTGRES_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ (index .Values .serviceName).postgres.existingSecret | default .Values.global.postgres.existingSecret | quote }}
      key: "username"
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ (index .Values .serviceName).postgres.existingSecret | default .Values.global.postgres.existingSecret | quote }}
      key: "password"
{{- else }}
- name: POSTGRES_HOST
  valueFrom:
    secretKeyRef:
      name: {{ include "cnc.fullname" . }}-{{ .serviceName }}-db-creds
      key: "host"
- name: POSTGRES_PORT
  valueFrom:
    secretKeyRef:
      name: {{ include "cnc.fullname" . }}-{{ .serviceName }}-db-creds
      key: "port"
- name: POSTGRES_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ include "cnc.fullname" . }}-{{ .serviceName }}-db-creds
      key: "username"
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "cnc.fullname" . }}-{{ .serviceName }}-db-creds
      key: "password"
{{- end }}
{{- end }}

{{- define "cnc.postgres.environment" }}
{{ include "postgres.common.environment" . }}
- name: POSTGRES_DATABASE
  value: {{ required "A valid postgres database (.Values.cim.postgres.database) entry is required." (index .Values .serviceName).postgres.database | quote }}
- name: POSTGRES_SSLMODE
  value: {{ (index .Values .serviceName).postgres.sslmode | default .Values.global.postgres.sslmode }}
{{- end }}


{{- define "cim.contextPath" -}}
{{- if .Values.cim.cimweb.contextPath -}}
{{- .Values.cim.cimweb.contextPath -}}/
{{- else -}}
{{- end -}}
{{- end -}}

{{/*
securityContext for the cnc pod level.
*/}}
{{- define "cnc.securityContext.pod" }}
  {{- $serviceName := "cim" }}
  {{- if (index .Values $serviceName).podSecurityContext }}
      {{- with (index .Values $serviceName).podSecurityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
  {{- else }}
      securityContext:
        runAsNonRoot: true
        {{- if .Capabilities.APIVersions.Has "security.openshift.io/v1" }}
        {{- else }}
        runAsUser: 5000
        {{- end }}
  {{- end }}
{{- end }}

{{/*
securityContext for the container level.
*/}}
{{- define "cnc.securityContext.container" }}
{{- $containerName := .containerName }}
{{- $securityContext := index .Values $containerName "containerSecurityContext" | default dict }}
{{- if $securityContext }}
securityContext:
  {{- toYaml $securityContext | nindent 2 }}
{{- else }}
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  {{ include "cnc.cim.setReadOnlyFileSystem" $containerName | nindent 2 }}
{{- if .Capabilities.APIVersions.Has "security.openshift.io/v1" }}
{{- else }}
  {{ include "cnc.cim.setRunAsUserId" $containerName | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}

{{/* vim: set filetype=mustache: */}}
{{/*
Renders a value that contains template.
Usage:
{{ include "common.tplvalues.render" ( dict "value" .Values.path.to.the.Value "context" $) }}
*/}}
{{- define "common.tplvalues.render" -}}
    {{- if typeIs "string" .value }}
        {{- tpl .value .context }}
    {{- else }}
        {{- tpl (.value | toYaml) .context }}
    {{- end }}
{{- end -}}

{{/*
Check if Kubernetes version is 1.28 or greater and return true or false.
Usage: {{- if isKubeVersionValid .Capabilities.KubeVersion.GitVersion }} ... {{- end }}
*/}}
{{- define "isKubeVersionValid" -}}
{{- $kubeMajorVersion := .Capabilities.KubeVersion.Major | int  }}
{{- $kubeMinorVersion := .Capabilities.KubeVersion.Minor | int }}
{{- if and (ge $kubeMajorVersion 1) (ge $kubeMinorVersion 28) }}
true
{{- end }}
{{- end }}


{{/* Common TlsSidecar Parameters */}}

{{- define "tlsSidecar.image.name" -}}
    {{ printf "%s/%s:%s" (required "A valid image registry entry is required." (.Values.cim.cimweb.tlsSidecar.registry | default .Values.imageRegistry | default .Values.global.imageRegistry )) (required "A valid image name (.Values.cim.cimweb.tlsSidecar.image) entry is required." .Values.cim.cimweb.tlsSidecar.image ) .Values.cim.cimweb.tlsSidecar.version }}
{{- end }}

{{- define "tlsSidecar.common.volumeMounts" }}
- name: nginx-cert
  mountPath: /app/cert
- name: nginx-config-volume
  mountPath: /etc/nginx
- name: nginx-dhparams
  mountPath: /tmp/ssl
- name: nginx-var-cache
  mountPath: /var/cache/nginx
- name: nginx-var-log
  mountPath: /var/log/nginx
- name: nginx-var-run
  mountPath: /var/run
{{- end }}

{{- define "tlsSidecar.common.ports" }}
- name: p8443
  containerPort: 8443
  protocol: TCP
{{- end }}

{{/* Common Cim Parameters */}}

{{- define "cimweb.common.annotations" }}
checksum/webapp-config: {{ include (print $.Template.BasePath "/webapp-config.yaml") . | sha256sum }}
checksum/nginx-config: {{ include (print $.Template.BasePath "/nginx-config.yaml") . | sha256sum }}
checksum/ldap-config: {{ include (print $.Template.BasePath "/ldap-secret.yaml") . | sha256sum }}
checksum/cim-secret: {{ include (print $.Template.BasePath "/cim-secret.yaml") . | sha256sum }}
{{- if .Values.cim.cimweb.exposeMetrics }}
prometheus.io/port: "8089"
prometheus.io/scrape: "true"
prometheus.io/path: {{ printf "/%smetrics" (include "cim.contextPath" .) | quote }}
{{- end }}
{{- with .Values.cim.cimweb.podAnnotations }}
  {{- toYaml . | nindent 0 }}
{{- end }}
{{- end }}

{{- define "cimweb.image.name" -}}
    {{ printf "%s/%s:%s%s" (required "A valid image registry entry is required." (.Values.cim.cimweb.registry | default .Values.imageRegistry | default .Values.global.imageRegistry )) (required "A valid image name (.Values.cim.cimweb.image) entry is required." .Values.cim.cimweb.image ) (.Values.cim.cimweb.version | default .Values.imageVersion | default .Values.global.imageVersion ) (.Values.imageTagSuffix | default .Values.global.imageTagSuffix) | quote }}
{{- end }}

{{- define "cimweb.common.environment" }}
- name: TRUST_STORE_PATH
  value: {{ include "connect.truststore.path" . | quote }}
- name: LOG_CONFIG
  value: ""
- name: PROPERTIES_PATH
  value: "/config/cim/cim.properties"
- name: JAVA_OPTS
  {{- /* cim.cimweb.tomcat.connectionTimeout: Spring Boot's server.tomcat.connection-timeout (CNC's Connect has no server.xml) */}}
  {{- $tomcatTimeout := dig "tomcat" "connectionTimeout" "" .Values.cim.cimweb }}
  value: {{ trim (printf "%s%s" (.Values.cim.cimweb.javaOpts | default "") (ternary (printf " -Dserver.tomcat.connection-timeout=%s" (toString $tomcatTimeout)) "" (ne (toString $tomcatTimeout) ""))) | quote }}
- name: CONTEXT_PATH
  value: {{ .Values.cim.cimweb.contextPath | quote }}
- name: LOAD_CERT_INTO_KEYSTORE
  value: {{ .Values.cim.cimweb.keystore.enabled | quote }}
- name: CIM_LDAP_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.cim.ldap.keySecret.existingSecret | default (printf "%s-ldap-encryption-key" (include "cnc.fullname" .)) }}
      key: "key"
{{- if (index .Values "scan-services").enabled }}
- name: SCAN_HOST
  value: {{printf "http://"}}{{ include "cnc.fullname" . }}-{{ printf "scan-service:9998/api/v2" }}
- name: STORAGE_HOST
  value: {{printf "http://"}}{{ include "cnc.fullname" . }}-{{ printf "storage-service:9998/api/v2"}}
- name: IMPERSONATION_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "cnc.fullname" . }}-impersonation-token
      key: "token"
{{- end }}
{{- if .Values.cim.cimweb.keystore.enabled }}
{{ include "keystore.common.environment" . }}
{{- end }}
{{- range $name, $value := .Values.cim.cimweb.environment }}
- name: {{ $name | quote }}
  value: {{ $value | quote }}
{{- end }}
{{- if gt (int .Values.cim.cimweb.replicas) 1 }}
- name: CACHE_PROVIDER
  value: infinispancache
- name: LOCK_PROVIDER
  value: jdbclocks
- name: SESSION_PROVIDER
  value: jdbcsessions
- name: INFINISPAN_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "cnc.fullname" . }}-cim-secret-key
      key: "token"
- name: SECRET_KEYSTORE_PATH
  value: {{ include "connect.secret.keystore.path" . | quote }}
{{- end }}
- name: COMMIT_URL
  value: https://{{ (index .Values.cim.ingress.hosts | default .Values.global.ingress.hosts 0) | toString | trimAll "[]" }}/ccd
- name: COMMIT_PROTOCOL
  value: rcp2
{{- if index .Values "triage-suggestion-service" "enabled" }}
{{- $tsgCfg := .Values.cim.cimweb.triageSuggestionService }}
- name: TRIAGE_SUGGESTION_AUTH_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $tsgCfg.authSecret.name }}
      key: {{ $tsgCfg.authSecret.key }}
{{- end }}
{{- end }}

{{- define "cimweb.common.volumeMounts" }}
- name: cim-secrets
  mountPath: /config/cim/cim.properties
  subPath: cim.properties
- name: cim-logging
  mountPath: /config/cim/cococo-log4j.xml
  subPath: cococo-log4j.xml
- name: cim-downloads
  mountPath: /coverity/server/base/webapps/downloads
- name: cim-docs
  mountPath: /coverity/webapp/doc
- name: cim-checker-policy
  mountPath: /coverity/webapp/checker-policy
- name: cim-reports
  mountPath: /coverity/reports
{{- if (index .Values "scan-services").enabled }}
- name: mtls-cert
  mountPath: /app/cert/mtls
{{- end }}
- name: cim-volume
  mountPath: /tmp
{{ include "common.volumeMounts" . }}
{{- if .Values.cim.cimweb.keystore.enabled }}
- name: cim-certificate
  mountPath: /config/cim/cert
{{- end }}
{{ if and (.Values.global.proxy.enabled) (eq (.Values.global.proxy.tlsmode) "mtls") }}
- name: proxy-certs
  mountPath: /opt/proxy-certs
{{ end }}
{{- end }}

{{- define "cimdownloads.image.name" -}}
    {{ printf "%s/%s:%s%s" (required "A valid image registry entry is required." (.Values.cim.cimdownloads.registry | default .Values.imageRegistry | default .Values.global.imageRegistry)) (required "A valid image name (.Values.cim.cimdownloads.image) entry is required." .Values.cim.cimdownloads.image) (.Values.cim.cimdownloads.version| default .Values.imageVersion | default .Values.global.imageVersion ) (.Values.imageTagSuffix | default .Values.global.imageTagSuffix) | quote }}
{{- end }}

{{- define "cimdocs.common.volumeMounts" }}
- name: cim-docs
  mountPath: /cimweb/docs
{{- end }}

{{- define "cimdownloads.common.volumeMounts" }}
- name: cim-downloads
  mountPath: /cimweb/downloads
- name: cim-checker-policy
  mountPath: /cimweb/checker-policy
{{- end }}

{{- define "cim.common.volumes" }}
{{- if or (index .Values "scan-services").enabled .Values.cim.cimweb.tlsSidecar.enabled }}
- name: nginx-config-volume
  configMap:
    name: {{ include "cnc.fullname" . }}-cim-nginx-config
- name: nginx-dhparams
  configMap:
    name: {{ include "cnc.fullname" . }}-cim-nginx-dhparams
- name: nginx-var-cache
  emptyDir: {}
- name: nginx-var-log
  emptyDir: {}
- name: nginx-var-run
  emptyDir: {}
{{- end }}
- name: cim-secrets
  secret:
    secretName: {{ include "cnc.fullname" . }}-cim-webapp-secrets
- name: cim-properties
  emptyDir: {}
- name: cim-logging
  configMap:
    name: {{ include "cnc.fullname" . }}-cim-logging-config
- name: cim-downloads
  emptyDir: {}
- name: cim-docs
  emptyDir: {}
- name: cim-checker-policy
  emptyDir: {}
- name: cim-reports
  emptyDir: {}
- name: cim-volume
  emptyDir: {}
{{ include "common.volumes" . }}
{{- if .Values.cim.cimweb.keystore.enabled }}
- name: cim-certificate
  secret:
    secretName: {{ required "A valid keystore certificate secret (.Values.cim.cimweb.keystore.certificateSecret) must be provided." .Values.cim.cimweb.keystore.certificateSecret }}
{{- end }}
{{- if and (.Values.global.proxy.enabled) (eq (.Values.global.proxy.tlsmode) "mtls") }}
- name: proxy-certs
  secret:
    defaultMode: 420
    secretName: {{ required "A proxy secret containing client certificates with key client-cert, client-key must be provided when the TLS mode is set to mtls." (.Values.global.proxy.existingSecret) }}
{{- end }}
{{- end }}

{{- define "cimweb.common.livenessProbeSettings" }}
initialDelaySeconds: 30
periodSeconds: 30
timeoutSeconds: 60
failureThreshold: 3
{{- end }}

{{- define "cimweb.common.livenessProbe" }}
httpGet:
  path: {{ printf "/%sliveness" (include "cim.contextPath" .) | quote }}
  port: 8080
{{ include "cimweb.common.livenessProbeSettings" . }}
{{- end }}

{{- define "cimweb.common.readinessProbe" }}
httpGet:
  path: {{ printf "/%slogin/login.htm" (include "cim.contextPath" .) | quote }}
  port: 8080
initialDelaySeconds: 30
periodSeconds: 45
timeoutSeconds: 30
failureThreshold: 3
{{- end }}

{{- define "cimweb.common.startUpProbeSettings" }}
initialDelaySeconds: 30
periodSeconds: 30
timeoutSeconds: 60
failureThreshold: 30
{{- end }}

{{- define "cimweb.common.startupProbe" }}
httpGet: 
  path: {{ printf "/%sliveness" (include "cim.contextPath" .) | quote }}
  port: 8080
{{ include "cimweb.common.startUpProbeSettings" . }}
{{- end }}

{{- define "cimweb.common.ports" }}
- name: p8080
  containerPort: 8080
  protocol: TCP
- name: metrics
  containerPort: 8089
  protocol: TCP
{{- if .Values.cim.cimweb.exposeCommitPort }}
- name: commit
  containerPort: {{ .Values.cim.cimweb.commitPort }}
  protocol: TCP
{{- end }}
{{- end }}

{{- define "cim.pgpool.postgres.environment" }}
- name: POSTGRES_HOST
  value: {{ include "cnc.fullname" . }}-pgpool-svc
- name: POSTGRES_PORT
  value: '9999'
- name: POSTGRES_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ if or .Values.global.postgres.existingSecret (index .Values .serviceName).postgres.existingSecret }}{{ (index .Values .serviceName).postgres.existingSecret | default .Values.global.postgres.existingSecret | quote }}{{ else }}{{ include "cnc.fullname" . }}-{{ .serviceName }}-db-creds{{ end}}
      key: "username"
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ if or .Values.global.postgres.existingSecret (index .Values .serviceName).postgres.existingSecret }}{{ (index .Values .serviceName).postgres.existingSecret | default .Values.global.postgres.existingSecret | quote }}{{ else }}{{ include "cnc.fullname" . }}-{{ .serviceName }}-db-creds{{ end}}
      key: "password"
- name: POSTGRES_DATABASE
  value: {{ required "A valid postgres database (.Values.cim.postgres.database) entry is required." (index .Values .serviceName).postgres.database | quote }}
- name: POSTGRES_SSLMODE
  value: disable
{{- end }}

{{- define "proxy.tlsmode" -}}
{{- $proxyTlsMode := .Values.global.proxy.tlsmode }}
{{- $property := required "A valid proxy tlsmode(tls|mtls|insecure) entry is required." $proxyTlsMode -}}
{{- if not (or (eq $property "tls") (eq $property "mtls") (eq $property "insecure")) -}}
  {{- fail "A valid proxy tlsmode(tls|mtls|insecure) entry is required." -}}
{{- else }}
  {{- printf "%s" $proxyTlsMode  }}
{{- end -}}
{{- end -}}

{{- define "keystore.common.environment" }}
- name: TLS_CERT_PATH
  value: {{ include "connect.tls.cert.path" . | quote }}
- name: TLS_KEY_PATH
  value: {{ include "connect.tls.key.path" . | quote }}
- name: KEYSTORE_PATH
  value: {{ include "connect.keystore.path" . | quote }}
- name: KEYSTORE_ALIAS
  value: {{ include "connect.keystore.alias" . | quote }}
{{- end }}

{{- define "common.volumes" }}
- name: cim-config
  emptyDir: {}
{{- if (index .Values.global "trust-stores").enabled }}
- name: importtruststorecerts
  configMap:
    name: {{ required "A valid trust-stores configmap name must be provided." ((index .Values.global "trust-stores").configmapName) }}
{{- end }}
{{- end }}

{{- define "common.volumeMounts" }}
- name: cim-config
  mountPath: /coverity/config
{{- if (index .Values.global "trust-stores").enabled }}
- name: importtruststorecerts
  mountPath: /coverity/truststorecerts
{{- end }}
{{- end }}

{{/*
Returns "true" when cim.gateway.gatewayClassName is "nginx" (NGINX Gateway Fabric).
NGF-specific resources (SnippetsFilter, SnippetsPolicy, ClientSettingsPolicy) are only
rendered when this returns true. Any other gateway implementation (GKE, EKS ALB, Azure
Application Gateway, Envoy, etc.) will not have these NGF-only CRDs applied, preventing
"no matches for kind" errors on clusters where those CRDs do not exist.
*/}}
{{- define "cnc.gateway.isNGF" -}}
{{- if eq (.Values.cim.gateway.gatewayClassName | default "") "nginx" -}}
true
{{- end -}}
{{- end -}}

{{/*
Returns "true" when cim.gateway.gatewayClassName starts with "gke-".
All GKE native Gateway classes share this prefix (e.g. gke-l7-global-external-managed,
gke-l7-regional-external-managed, gke-l7-rilb, gke-l7-gxlb).
Using the prefix rather than an exact match keeps this future-proof.
When true: GKE HealthCheckPolicy resources are created. GKE Gateway API provisions NEGs
automatically — no annotation needed.
*/}}
{{- define "cnc.gateway.isGKE" -}}
{{- if hasPrefix "gke-" (.Values.cim.gateway.gatewayClassName | default "") -}}
true
{{- end -}}
{{- end -}}


{{/*
Returns "true" when cim.gateway.gatewayClassName starts with "azure-alb".
Matches all Azure ALB GatewayClass variants (azure-alb-external, azure-alb-internal).
When true: ALB binding annotations are added to the Gateway and ALB-specific HealthCheckPolicy
resources are rendered. Azure ALB requires explicit annotations to associate the Gateway with an
ApplicationLoadBalancer CR — unlike GKE, it does not auto-provision from the GatewayClass alone.
*/}}
{{- define "cnc.gateway.isAzureALB" -}}
{{- if hasPrefix "azure-alb" (.Values.cim.gateway.gatewayClassName | default "") -}}
true
{{- end -}}
{{- end -}}

{{/*
Returns "true" when cim.gateway.gatewayClassName is "amazon-alb" or starts with "amazon-".
AWS Gateway API uses the AWS Load Balancer Controller with gatewayClassName "amazon-alb".
When true: AWS TargetGroupConfiguration resources are created for health checks.
LoadBalancerConfiguration must be created manually by the customer and referenced via
cim.gateway.infrastructure.parametersRef.name.
*/}}
{{- define "cnc.gateway.isAWS" -}}
{{- $className := .Values.cim.gateway.gatewayClassName | default "" -}}
{{- if or (eq $className "amazon-alb") (hasPrefix "amazon-" $className) -}}
true
{{- end -}}
{{- end -}}

{{/*
Build the filters block for a single HTTPRoute rule.
Merges raw filters[] with the SnippetsFilter ExtensionRef for IP allowlisting.
The ExtensionRef is only added when isNGF=true (SnippetsFilter is an NGF-only CRD).
Usage: {{- include "cnc.gateway.ruleFilters" (dict "gw" $gw "fullName" $fullName "isNGF" (include "cnc.gateway.isNGF" .)) | nindent 6 }}
Outputs nothing when no filters are configured.
*/}}
{{- define "cnc.gateway.ruleFilters" -}}
{{- $gw := .gw -}}
{{- $fullName := .fullName -}}
{{- $isNGF := .isNGF -}}
{{- $hasSnippetsFilter := and $gw.allowedSourceRanges (eq $isNGF "true") -}}
{{- if or $gw.filters $hasSnippetsFilter -}}
filters:
  {{- if $gw.filters }}
  {{- toYaml $gw.filters | nindent 2 }}
  {{- end }}
  {{- if $hasSnippetsFilter }}
  - type: ExtensionRef
    extensionRef:
      group: gateway.nginx.org
      kind: SnippetsFilter
      name: {{ $fullName }}-cim-ip-allowlist
  {{- end }}
{{- end -}}
{{- /* cim.gateway.timeouts: the rule's Gateway API timeouts (Envoy Gateway's 15 s default cuts long downloads) */ -}}
{{- with $gw.timeouts }}
timeouts:
  {{- toYaml . | nindent 2 }}
{{- end -}}
{{- end -}}

{{- define "cnc.initContainer.waitForPostgres" -}}
  {{- $postgresHost := .Values.cim.postgres.host | default .Values.global.postgres.host }}
  {{- $postgresPort := .Values.cim.postgres.port | default .Values.global.postgres.port | default 5432 }}
  - name: wait-for-postgres
    image: {{ printf "%s/%s:%s%s" (required "A valid image registry entry is required." (.Values.cim.cimtools.registry | default .Values.imageRegistry | default .Values.global.imageRegistry )) (required "A valid image name (.Values.cim.cimtools.image) entry is required." .Values.cim.cimtools.image ) (.Values.cim.cimtools.version | default .Values.imageVersion | default .Values.global.imageVersion) (.Values.imageTagSuffix| default .Values.global.imageTagSuffix) | quote }}
    resources:
      requests:
        memory: "256Mi"
        cpu: "100m"
      limits:
        memory: "512Mi"
        cpu: "200m"
    env:
      - name: POSTGRES_HOST
        value: {{ $postgresHost | quote }}
      - name: POSTGRES_PORT
        value: {{ $postgresPort | quote }}
      - name: POSTGRES_USERNAME
        value: {{ .Values.cim.postgres.user | default .Values.global.postgres.user | quote }}
    command:
      - /bin/sh
      - -c
      - |
        set -e
        echo "Waiting for PostgreSQL at ${POSTGRES_HOST}:${POSTGRES_PORT}..."

        check_postgres() {
          pg_isready -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USERNAME}" -q
          return $?
        }

        check_postgres_stable() {
          local count=0
          local required_stable_checks=3

          while [ $count -lt $required_stable_checks ]; do
            if check_postgres; then
              count=$((count + 1))
              echo "PostgreSQL ready check $count/$required_stable_checks"
              sleep 2
            else
              echo "PostgreSQL not ready, restarting stability check..."
              count=0
              sleep 5
            fi
          done
          return 0
        }

        timeout=600
        elapsed=0

        while ! check_postgres; do
          if [ $elapsed -ge $timeout ]; then
            echo "ERROR: PostgreSQL not ready after ${timeout}s"
            exit 1
          fi
          echo "Waiting for PostgreSQL... (${elapsed}s/${timeout}s)"
          sleep 5
          elapsed=$((elapsed + 5))
        done

        echo "PostgreSQL is responding, checking stability..."
        check_postgres_stable
        echo "PostgreSQL is ready and stable"
  {{- end -}}
