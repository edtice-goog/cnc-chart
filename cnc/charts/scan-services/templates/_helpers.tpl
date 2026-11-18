{{/* vim: set filetype=mustache: */}}
{{/* Expand the name of the chart. */}}
{{- define "scan-services.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name. */}}
{{- define "scan-services.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Create chart name and version as used by the chart label. */}}
{{- define "scan-services.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels */}}
{{- define "chart.labels" -}}
app.kubernetes.io/name: {{ include "scan-services.name" . }}
helm.sh/chart: {{ include "scan-services.chart" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: "{{ include "scan-services.app-version" . }}"
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
chart: {{ .Chart.Name | quote }}
{{- end -}}

{{- define "service.labels" -}}
helm.sh/chart: {{ include "scan-services.chart" . }}
{{ include "service.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: "{{ include "scan-services.app-version" . }}"
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "service.selectorLabels" -}}
app.kubernetes.io/name: {{ .serviceName }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ .serviceName }}
app.kubernetes.io/part-of: coverity
{{- end }}

{{- define "scan-services.app-version" -}}
{{- printf "%s" .Chart.AppVersion | replace "+" "_" | replace ":" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
https://github.com/openstack/openstack-helm-infra/blob/master/helm-toolkit/templates/utils/_joinListWithComma.tpl
*/}}
{{- define "helm-toolkit.utils.joinListWithComma" -}}
{{- $local := dict "first" true -}}
{{- range $k, $v := . -}}{{- if not $local.first -}},{{- end -}}{{- $v -}}{{- $_ := set $local "first" false -}}{{- end -}}
{{- end -}}

{{/*
Auto-select image name based on mode if not explicitly set.
For Polaris/Altair mode: scan-jobs-svc
For other modes (CNC, SRM, etc.): scan-service
*/}}
{{- define "scan-services.default.image.name" -}}
    {{- if or (eq .Values.mode "POLARIS") (eq .Values.mode "ALTAIR") -}}
        {{- "scan-jobs-svc" -}}
    {{- else -}}
        {{- "scan-service" -}}
    {{- end -}}
{{- end -}}

{{/*
Auto-select migration image name based on mode if not explicitly set.
For Polaris/Altair mode: scan-jobs-svc-migration
For other modes (CNC, SRM, etc.): scan-service-migration
*/}}
{{- define "scan-services.default.migration.image.name" -}}
    {{- if or (eq .Values.mode "POLARIS") (eq .Values.mode "ALTAIR") -}}
        {{- "scan-jobs-svc-migration" -}}
    {{- else -}}
        {{- "scan-service-migration" -}}
    {{- end -}}
{{- end -}}

{{- define "scan-services.image.name" -}}
    {{ printf "%s/%s:%s%s" (required "A valid image registry entry is required." ((index .Values .serviceName).registry | default .Values.imageRegistry | default .Values.global.imageRegistry)) (required "A valid image name entry is required." ((index .Values .serviceName).image | default (include "scan-services.default.image.name" .))) ((index .Values .serviceName).version | default .Values.imageVersion | default .Values.global.imageVersion) (.Values.imageTagSuffix | default .Values.global.imageTagSuffix) | quote }}
{{- end }}

{{- define "scan-services.migrationimage.name" -}}
    {{ printf "%s/%s:%s%s" (required "A valid image registry entry is required." ((index .Values .serviceName).migrateJob.registry |  default .Values.imageRegistry | default .Values.global.imageRegistry )) (required "A valid image name entry is required." ((index .Values .serviceName).migrateJob.image | default (include "scan-services.default.migration.image.name" .))) ((index .Values .serviceName).migrateJob.version | default .Values.imageVersion | default .Values.global.imageVersion) (.Values.imageTagSuffix | default .Values.global.imageTagSuffix) | quote }}
{{- end }}


{{- define "scan-services.postgres.secret" }}
{{- if not (or .Values.postgres.existingSecret .Values.global.postgres.existingSecret (index .Values .serviceName).postgres.existingSecret) }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "scan-services.fullname" . }}-{{ .serviceName }}-db-creds
  namespace: {{ .Release.Namespace }}
  annotations:
    helm.sh/hook-weight: "-14"
    helm.sh/hook: pre-upgrade, pre-install
type: Opaque
stringData:
  host: {{ required "A valid postgres host entry is required." ((index .Values .serviceName).postgres.host | default .Values.postgres.host | default .Values.global.postgres.host) | quote }}
  port: {{ required "A valid postgres port entry is required." ((index .Values .serviceName).postgres.port | default .Values.postgres.port | default .Values.global.postgres.port) | quote }}
  username: {{ required "A valid postgres username entry is required." ((index .Values .serviceName).postgres.user | default .Values.postgres.user | default .Values.global.postgres.user) | quote }}
  password: {{ required "A valid postgres password entry is required." ((index .Values .serviceName).postgres.password | default .Values.postgres.password | default .Values.global.postgres.password) | quote }}
{{- end }}
{{- end }}

{{- define "scan-services.postgres.environment" }}
{{- if or .Values.postgres.existingSecret .Values.global.postgres.existingSecret (index .Values .serviceName).postgres.existingSecret }}
- name: POSTGRES_HOST
  valueFrom:
    secretKeyRef:
      name: {{ (index .Values .serviceName).postgres.existingSecret | default .Values.postgres.existingSecret | default .Values.global.postgres.existingSecret | quote }}
      key: "host"
- name: POSTGRES_PORT
  valueFrom:
    secretKeyRef:
      name: {{ (index .Values .serviceName).postgres.existingSecret | default .Values.postgres.existingSecret | default .Values.global.postgres.existingSecret | quote }}
      key: "port"
- name: POSTGRES_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ (index .Values .serviceName).postgres.existingSecret | default .Values.postgres.existingSecret | default .Values.global.postgres.existingSecret | quote }}
      key: "username"
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ (index .Values .serviceName).postgres.existingSecret | default .Values.postgres.existingSecret | default .Values.global.postgres.existingSecret | quote }}
      key: "password"
{{- else }}
- name: POSTGRES_HOST
  valueFrom:
    secretKeyRef:
      name: {{ include "scan-services.fullname" . }}-{{ .serviceName }}-db-creds
      key: "host"
- name: POSTGRES_PORT
  valueFrom:
    secretKeyRef:
      name: {{ include "scan-services.fullname" . }}-{{ .serviceName }}-db-creds
      key: "port"
- name: POSTGRES_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ include "scan-services.fullname" . }}-{{ .serviceName }}-db-creds
      key: "username"
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "scan-services.fullname" . }}-{{ .serviceName }}-db-creds
      key: "password"
{{- end }}
- name: POSTGRES_DATABASE
  value: {{ required "A valid postgres database entry is required." (index .Values .serviceName).postgres.database | quote }}
{{- end }}

{{/*
securityContext for the scan-services pod level.
*/}}
{{- define "scan-services.securityContext.pod" }}
  {{- if (index .Values .serviceName).podSecurityContext }}
      {{- with (index .Values .serviceName).podSecurityContext }}
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
securityContext for the scan-services container level.
*/}}
{{- define "scan-services.securityContext.container" }}
{{- $containerName := .containerName }}
{{- $securityContext := index .Values $containerName "containerSecurityContext" | default dict }}
{{- if $securityContext }}
securityContext:
  {{- toYaml $securityContext | nindent 2 }}
{{- else }}
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
{{- if .Capabilities.APIVersions.Has "security.openshift.io/v1" }}
{{- else }}
  runAsUser: 5000
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

{{/*
it will generate a secret with random string.
*/}}
{{- define "scan-services.scanimpersonation.secret" }}
{{- $secretName := include "scan-services.fullname" . -}}
{{- $tokenSecretName := printf "%s-impersonation-token" $secretName -}}
{{- $existingSecret := lookup "v1" "Secret" .Release.Namespace $tokenSecretName | default "" -}}
{{- $existingSecretStr := toString $existingSecret -}}
{{- if eq $existingSecretStr "" -}}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "scan-services.fullname" . }}-impersonation-token
  namespace: {{ .Release.Namespace }}
  annotations:
    helm.sh/hook-weight: "-9"
    helm.sh/hook:  pre-upgrade, pre-install
type: Opaque
stringData:
  token:  "{{- randAlphaNum 16 | nospace -}}"
{{- end }}
{{- end }}

{{- define "generateTLShosts" -}}
  {{- $protocol := "" }}
  {{- if or (index .Values "ingress").tls (index .Values "global").ingress.tls }}
    {{- $protocol = "https://" }}
  {{- else }}
    {{- $protocol = "http://" }}
  {{- end }}
  {{- $hosts := "" }}
  {{- range $host := (index .Values "ingress").hosts | default (index .Values "global").ingress.hosts -}}
    {{- $hosts = printf "%s%s%s " $hosts $protocol $host -}}
  {{- end -}}
  {{- $hosts |trimSuffix " " | splitList " " | join "," }}
{{- end }}

{{/*
Resource Version of a connect-config.
Note: Helps to restart the service if the ConfigMap is Updated.
*/}}
{{- define "scan-services.connectConfig.resourceVersion" -}}
{{- $configMapPrefix := include "scan-services.fullname" . -}}
{{- $configMapName := printf "%s-connect-config" $configMapPrefix -}}
{{- $existingConnectConfigMap := lookup "v1" "ConfigMap" .Release.Namespace $configMapName | default "" -}}
{{- $existingConnectConfigMapStr := toString $existingConnectConfigMap -}}
{{- if ne $existingConnectConfigMapStr "" }}
{{- $existingConnectConfigMapResourceVersion :=  (lookup "v1" "ConfigMap" .Release.Namespace $configMapName).metadata.resourceVersion -}}
{{- printf "%s" $existingConnectConfigMapResourceVersion }}
{{- else }}
{{- printf "%s" "" }}
{{- end }}
{{- end }}

{{- define "proxy.url" -}}
  {{- $proxyHost := required "A valid proxy host entry is required." (.Values.proxy.host | default .Values.global.proxy.host) }}
  {{- $proxyPort := required "A valid proxy port entry is required." (.Values.proxy.port | default .Values.global.proxy.port) }}
  {{- $proxyPortStr := toString $proxyPort -}}
  {{- if eq (.Values.proxy.tlsmode | default .Values.global.proxy.tlsmode) "insecure" }}
    {{- printf "http://%s:%s" $proxyHost $proxyPortStr }}
  {{- else }}
    {{- printf "https://%s:%s" $proxyHost $proxyPortStr }}
  {{- end }}
{{- end }}

{{- define "proxy.tlsmode" -}}
{{- $proxyTlsMode := .Values.proxy.tlsmode | default .Values.global.proxy.tlsmode }}
{{- $property := required "A valid proxy tlsmode(tls|mtls|insecure) entry is required." $proxyTlsMode -}}
{{- if not (or (eq $property "tls") (eq $property "mtls") (eq $property "insecure")) -}}
  {{- fail "A valid proxy tlsmode(tls|mtls|insecure) entry is required." -}}
{{- else }}
  {{- printf "%s" $proxyTlsMode  }}
{{- end -}}
{{- end -}}

{{- define "storage.custom.serviceAccount" -}}
{{- $storageType := (index .Values .serviceName).storageType }}
{{- $serviceAccount := (index .Values .serviceName $storageType).serviceAccount }}
serviceAccountName: {{ required (printf "A valid %s service account name entry is required." $storageType) $serviceAccount }}
serviceAccount: {{ required (printf "A valid %s service account name entry is required." $storageType) $serviceAccount }}
{{- end -}}
