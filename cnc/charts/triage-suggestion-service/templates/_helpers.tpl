{{/*
Validate PRODUCT_MODE — must be "CNC" or "POLARIS".
*/}}
{{- define "triage-suggestion-service.validateProductMode" -}}
{{- $mode := index .Values.global.environment "PRODUCT_MODE" | default "CNC" -}}
{{- if and (ne $mode "CNC") (ne $mode "POLARIS") -}}
  {{- fail (printf "global.environment.PRODUCT_MODE must be \"CNC\" or \"POLARIS\", got: %q" $mode) -}}
{{- end -}}
{{- end }}

{{/*
Expand the name of the chart.
*/}}
{{- define "triage-suggestion-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "triage-suggestion-service.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "triage-suggestion-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "triage-suggestion-service.labels" -}}
helm.sh/chart: {{ include "triage-suggestion-service.chart" . }}
{{ include "triage-suggestion-service.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "triage-suggestion-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "triage-suggestion-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Artifact storage environment variables
Maps structured .Values.artifactStorage to flat env vars consumed by the Go service.
Falls back to .Values.global.artifactStorage for umbrella chart inheritance.
*/}}
{{- define "triage-suggestion-service.storageEnvVars" -}}
{{- $storage := .Values.artifactStorage | default dict }}
{{- $globalStorage := .Values.global.artifactStorage | default dict }}
{{- $storageType := $storage.storageType | default $globalStorage.storageType }}
{{- if $storageType }}
- name: ARTIFACTSTORAGETYPE
  value: {{ $storageType | quote }}
{{- end }}
{{- $maxSize := $storage.maxSize | default $globalStorage.maxSize }}
{{- if $maxSize }}
- name: ARTIFACTMAXSIZE
  value: {{ $maxSize | quote }}
{{- end }}
{{- $uploadExp := $storage.uploadUrlExpiration | default $globalStorage.uploadUrlExpiration }}
{{- if $uploadExp }}
- name: UPLOADURLEXPIRATION
  value: {{ $uploadExp | quote }}
{{- end }}
{{- $storagePath := $storage.storagePath | default $globalStorage.storagePath }}
{{- if $storagePath }}
- name: ARTIFACTSTORAGEPATH
  value: {{ $storagePath | quote }}
{{- end }}
{{- if eq ($storageType | default "") "s3" }}
{{- $localS3 := $storage.s3 | default dict }}
{{- $globalS3 := $globalStorage.s3 | default dict }}
- name: S3_BUCKET
  value: {{ $localS3.bucket | default $globalS3.bucket | quote }}
- name: S3_REGION
  value: {{ $localS3.region | default $globalS3.region | quote }}
{{- $s3Secret := ($localS3.secret | default $globalS3.secret) | default dict }}
{{- if $s3Secret.name }}
- name: S3_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ $s3Secret.name }}
      key: aws_access_key
- name: S3_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $s3Secret.name }}
      key: aws_secret_key
{{- end }}
{{- end }}
{{- if eq ($storageType | default "") "gcs" }}
{{- $localGcs := $storage.gcs | default dict }}
{{- $globalGcs := $globalStorage.gcs | default dict }}
- name: GCS_BUCKET
  value: {{ $localGcs.bucket | default $globalGcs.bucket | quote }}
{{- $gcsSAEmail := $localGcs.serviceAccountEmail | default $globalGcs.serviceAccountEmail }}
{{- if $gcsSAEmail }}
- name: GCS_SERVICE_ACCOUNT_EMAIL
  value: {{ $gcsSAEmail | quote }}
{{- end }}
{{- $gcsSecret := ($localGcs.secret | default $globalGcs.secret) | default dict }}
{{- if $gcsSecret.name }}
- name: GCS_CREDENTIALS_FILE
  value: "/secrets/gcs/{{ $gcsSecret.key | default "key.json" }}"
{{- end }}
{{- end }}
{{- if eq ($storageType | default "") "azure" }}
{{- $localAzure := $storage.azure | default dict }}
{{- $globalAzure := $globalStorage.azure | default dict }}
- name: AZURE_STORAGE_ACCOUNT
  value: {{ $localAzure.storageAccountName | default $globalAzure.storageAccountName | quote }}
- name: AZURE_STORAGE_CONTAINER
  value: {{ $localAzure.container | default $globalAzure.container | quote }}
{{- $azureSecret := ($localAzure.secret | default $globalAzure.secret) | default dict }}
{{- if $azureSecret.name }}
- name: AZURE_STORAGE_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $azureSecret.name }}
      key: azure_storage_key
{{- end }}
{{- end }}
{{- if eq ($storageType | default "") "minio" }}
{{- $localMinio := $storage.minio | default dict }}
{{- $globalMinio := $globalStorage.minio | default dict }}
- name: S3_ENDPOINT
  value: {{ $localMinio.endpoint | default $globalMinio.endpoint | quote }}
- name: S3_BUCKET
  value: {{ $localMinio.bucket | default $globalMinio.bucket | quote }}
- name: S3_REGION
  value: {{ $localMinio.region | default $globalMinio.region | default "us-east-1" | quote }}
- name: S3_USE_SSL
  value: {{ $localMinio.secure | default $globalMinio.secure | default false | quote }}
- name: S3_PATH_STYLE
  value: {{ $localMinio.pathStyle | default $globalMinio.pathStyle | default true | quote }}
{{- $minioSecret := ($localMinio.secret | default $globalMinio.secret) | default dict }}
{{- if $minioSecret.name }}
- name: S3_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ $minioSecret.name }}
      key: root-user
- name: S3_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $minioSecret.name }}
      key: root-password
{{- end }}
{{- end }}
{{- end }}

{{/*
PostgreSQL secret name.
Returns the name of the Kubernetes Secret that holds postgres credentials.
Priority: postgres.existingSecret > global.postgres.existingSecret > auto-generated secret.
If no secret exists (no existingSecret and no host configured), returns empty string.
*/}}
{{- define "triage-suggestion-service.postgresSecretName" -}}
{{- $pg := .Values.postgres | default dict }}
{{- $globalPg := .Values.global.postgres | default dict }}
{{- $existingSecret := $pg.existingSecret | default $globalPg.existingSecret }}
{{- if $existingSecret -}}
{{ $existingSecret }}
{{- else if ($pg.host | default $globalPg.host) -}}
{{ include "triage-suggestion-service.fullname" . }}-db-creds
{{- end -}}
{{- end -}}

{{/*
PostgreSQL environment variables.
When a postgres secret is available (existingSecret or auto-generated from postgres.host),
injects POSTGRES_HOST/PORT/USERNAME/PASSWORD via secretKeyRef — matching the CNC umbrella
chart pattern used by scan-service and other services.
Falls back to plain value: entries for standalone/dev deployments where no secret exists.
Always emits POSTGRES_DB/POSTGRES_DATABASE and POSTGRES_SSLMODE as plain values.
Emits POSTGRES_SSLROOTCERT for CA certificate verification (mounted via trust-stores ConfigMap).
Emits connection pool settings (POSTGRES_MAX_OPEN_CONNS, POSTGRES_MAX_IDLE_CONNS,
POSTGRES_CONN_MAX_LIFETIME) when configured via .Values.postgres or .Values.global.postgres.
*/}}
{{- define "triage-suggestion-service.postgresEnvVars" -}}
{{- $pg := .Values.postgres | default dict }}
{{- $globalPg := .Values.global.postgres | default dict }}
{{- $secretName := include "triage-suggestion-service.postgresSecretName" . }}
{{- if $secretName }}
- name: POSTGRES_HOST
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: "host"
- name: POSTGRES_PORT
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: "port"
- name: POSTGRES_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: "username"
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: "password"
{{- end }}
{{- $database := $pg.database | default $globalPg.database }}
{{- if $database }}
- name: POSTGRES_DB
  value: {{ $database | quote }}
- name: POSTGRES_DATABASE
  value: {{ $database | quote }}
{{- end }}
{{- $sslmode := $pg.sslmode | default $globalPg.sslmode }}
{{- if $sslmode }}
- name: POSTGRES_SSLMODE
  value: {{ $sslmode | quote }}
{{- end }}
{{- $sslRootCert := $pg.sslRootCert | default $globalPg.sslRootCert }}
{{- if $sslRootCert }}
- name: POSTGRES_SSLROOTCERT
  value: {{ $sslRootCert | quote }}
{{- end }}
{{- $maxOpenConns := $pg.maxOpenConns | default $globalPg.maxOpenConns }}
{{- if $maxOpenConns }}
- name: POSTGRES_MAX_OPEN_CONNS
  value: {{ $maxOpenConns | quote }}
{{- end }}
{{- $maxIdleConns := $pg.maxIdleConns | default $globalPg.maxIdleConns }}
{{- if $maxIdleConns }}
- name: POSTGRES_MAX_IDLE_CONNS
  value: {{ $maxIdleConns | quote }}
{{- end }}
{{- $connMaxLifetime := $pg.connMaxLifetime | default $globalPg.connMaxLifetime }}
{{- if $connMaxLifetime }}
- name: POSTGRES_CONN_MAX_LIFETIME
  value: {{ $connMaxLifetime | quote }}
{{- end }}
{{- end -}}

{{/*
RabbitMQ hostname.
When the bundled rabbitmq subchart is enabled, derives the service name from fullnameOverride
or the standard Helm fullname convention. When disabled, falls back to externalRabbitmq.host.
*/}}
{{- define "triage-suggestion-service.rabbitmqHost" -}}
{{- if .Values.rabbitmq.enabled -}}
{{- .Values.rabbitmq.fullnameOverride | default (printf "%s-rabbitmq" (include "triage-suggestion-service.fullname" .)) -}}
{{- else -}}
{{- .Values.externalRabbitmq.host | default "rabbitmq" -}}
{{- end -}}
{{- end -}}

{{/*
RabbitMQ port.
*/}}
{{- define "triage-suggestion-service.rabbitmqPort" -}}
{{- if .Values.rabbitmq.enabled -}}
{{- 5672 -}}
{{- else -}}
{{- .Values.externalRabbitmq.port | default 5672 -}}
{{- end -}}
{{- end -}}

{{/*
RabbitMQ secret name.
The bitnami rabbitmq chart creates a secret with the same name as its fullname,
containing the key "rabbitmq-password".
*/}}
{{- define "triage-suggestion-service.rabbitmqSecretName" -}}
{{- if .Values.rabbitmq.enabled -}}
{{- .Values.rabbitmq.fullnameOverride | default (printf "%s-rabbitmq" (include "triage-suggestion-service.fullname" .)) -}}
{{- else -}}
{{- .Values.externalRabbitmq.existingSecret | default "triage-suggestion-service-secrets" -}}
{{- end -}}
{{- end -}}

{{/*
RabbitMQ secret key for the password.
*/}}
{{- define "triage-suggestion-service.rabbitmqSecretKey" -}}
{{- if .Values.rabbitmq.enabled -}}
rabbitmq-password
{{- else -}}
{{- .Values.externalRabbitmq.existingSecretKey | default "rabbitmq-password" -}}
{{- end -}}
{{- end -}}

{{/*
RabbitMQ environment variables.
Injects MQ_HOST, MQ_PORT, and MQ_PASSWORD from the appropriate source
(bundled subchart or external configuration).
Also injects MQ_TLS_* env vars when TLS is enabled on the external RabbitMQ.
*/}}
{{- define "triage-suggestion-service.mqEnvVars" -}}
- name: MQ_HOST
  value: {{ include "triage-suggestion-service.rabbitmqHost" . | quote }}
- name: MQ_PORT
  value: {{ include "triage-suggestion-service.rabbitmqPort" . | quote }}
- name: MQ_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "triage-suggestion-service.rabbitmqSecretName" . }}
      key: {{ include "triage-suggestion-service.rabbitmqSecretKey" . | trim }}
{{- if not .Values.rabbitmq.enabled }}
{{- $extMq := .Values.externalRabbitmq | default dict }}
{{- $mqTls := $extMq.tls | default dict }}
{{- if $mqTls.enabled }}
- name: MQ_TLS_ENABLED
  value: "true"
{{- if $mqTls.secret }}
- name: MQ_TLS_CA_CERT_FILE
  value: "/etc/mq-tls/ca.crt"
- name: MQ_TLS_CERT_FILE
  value: "/etc/mq-tls/tls.crt"
- name: MQ_TLS_KEY_FILE
  value: "/etc/mq-tls/tls.key"
{{- end }}
{{- if $mqTls.insecureSkipVerify }}
- name: MQ_TLS_INSECURE_SKIP_VERIFY
  value: "true"
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
RabbitMQ TLS volume mounts.
Mounts the TLS certificate files when TLS is enabled on the external RabbitMQ.
*/}}
{{- define "triage-suggestion-service.mqTlsVolumeMounts" -}}
{{- if not .Values.rabbitmq.enabled }}
{{- $extMq := .Values.externalRabbitmq | default dict }}
{{- $mqTls := $extMq.tls | default dict }}
{{- if and $mqTls.enabled $mqTls.secret }}
- name: mq-tls
  mountPath: /etc/mq-tls
  readOnly: true
{{- end }}
{{- end }}
{{- end -}}

{{/*
RabbitMQ TLS volumes.
Provides the TLS certificates from a Kubernetes Secret when TLS is enabled.
*/}}
{{- define "triage-suggestion-service.mqTlsVolumes" -}}
{{- if not .Values.rabbitmq.enabled }}
{{- $extMq := .Values.externalRabbitmq | default dict }}
{{- $mqTls := $extMq.tls | default dict }}
{{- if and $mqTls.enabled $mqTls.secret }}
- name: mq-tls
  secret:
    secretName: {{ $mqTls.secret }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
GCS credentials volume mounts.
Mounts the GCS service account JSON key file when storage type is "gcs"
and a secret is configured.
*/}}
{{- define "triage-suggestion-service.gcsVolumeMounts" -}}
{{- $storage := .Values.artifactStorage | default dict }}
{{- $globalStorage := .Values.global.artifactStorage | default dict }}
{{- $storageType := $storage.storageType | default $globalStorage.storageType }}
{{- if eq ($storageType | default "") "gcs" }}
{{- $localGcs := $storage.gcs | default dict }}
{{- $globalGcs := $globalStorage.gcs | default dict }}
{{- $gcsSecret := ($localGcs.secret | default $globalGcs.secret) | default dict }}
{{- if $gcsSecret.name }}
- name: gcs-credentials
  mountPath: /secrets/gcs
  readOnly: true
{{- end }}
{{- end }}
{{- end -}}

{{/*
GCS credentials volumes.
Provides the GCS service account JSON key from a Kubernetes Secret
when storage type is "gcs" and a secret is configured.
*/}}
{{- define "triage-suggestion-service.gcsVolumes" -}}
{{- $storage := .Values.artifactStorage | default dict }}
{{- $globalStorage := .Values.global.artifactStorage | default dict }}
{{- $storageType := $storage.storageType | default $globalStorage.storageType }}
{{- if eq ($storageType | default "") "gcs" }}
{{- $localGcs := $storage.gcs | default dict }}
{{- $globalGcs := $globalStorage.gcs | default dict }}
{{- $gcsSecret := ($localGcs.secret | default $globalGcs.secret) | default dict }}
{{- if $gcsSecret.name }}
- name: gcs-credentials
  secret:
    secretName: {{ $gcsSecret.name }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Trust-stores volume mounts.
Adds a volumeMount for custom CA certificates when trust-stores is enabled
at either the chart level or via global values.
*/}}
{{- define "triage-suggestion-service.trustStoresVolumeMounts" -}}
{{- $ts := index .Values "trust-stores" | default dict }}
{{- $globalTs := index .Values.global "trust-stores" | default dict }}
{{- if or $ts.enabled $globalTs.enabled }}
- name: trust-stores
  mountPath: /opt/postgresql/ssl
  readOnly: true
{{- end }}
{{- end -}}

{{/*
Trust-stores volumes.
Adds a volume sourced from a ConfigMap containing custom CA certificates
when trust-stores is enabled at either the chart level or via global values.
*/}}
{{- define "triage-suggestion-service.trustStoresVolumes" -}}
{{- $ts := index .Values "trust-stores" | default dict }}
{{- $globalTs := index .Values.global "trust-stores" | default dict }}
{{- if or $ts.enabled $globalTs.enabled }}
- name: trust-stores
  configMap:
    name: {{ $ts.configmapName | default $globalTs.configmapName | default "connect-trust-stores" }}
{{- end }}
{{- end -}}

{{/*
LLM environment variables.
Injects LLM_URL and LLM_NAME from .Values.llm configuration.
Note: LLM API keys are no longer configured globally. They are provided
per-request via POST /auth (encrypted with ECIES, stored in JWE token).
*/}}
{{- define "triage-suggestion-service.llmEnvVars" -}}
{{- $llm := .Values.llm | default dict }}
{{- if $llm.url }}
- name: LLM_URL
  value: {{ $llm.url | quote }}
{{- end }}
{{- if $llm.name }}
- name: LLM_NAME
  value: {{ $llm.name | quote }}
{{- end }}
{{- end -}}

{{/*
Vault KV address.
When the bundled triage-vault subchart is enabled, derives the service address
from the standard Vault Helm chart naming convention.
When disabled, falls back to externalVault.addr.
*/}}
{{- define "triage-suggestion-service.vaultAddr" -}}
{{- if (index .Values "triage-vault").enabled -}}
{{- $tv := index .Values "triage-vault" -}}
{{- $name := $tv.fullnameOverride | default (printf "%s-triage-vault" .Release.Name) -}}
{{- printf "http://%s:8200" $name -}}
{{- else -}}
{{- .Values.externalVault.addr | default "" -}}
{{- end -}}
{{- end -}}

{{/*
Vault KV environment variables.
Injects VAULT_KV_* env vars from either the bundled triage-vault subchart
or the externalVault configuration. Uses VAULT_KV_ prefix to avoid conflicts
with CNC Vault Agent sidecar env vars (VAULT_AUTH_METHOD, VAULT_DBSECRETPATH, etc.).
Only emitted when Vault KV is enabled (bundled subchart or externalVault.addr set).
*/}}
{{- define "triage-suggestion-service.vaultEnvVars" -}}
{{- $vaultAddr := include "triage-suggestion-service.vaultAddr" . }}
{{- if $vaultAddr }}
- name: VAULT_KV_ENABLED
  value: "true"
- name: VAULT_KV_ADDR
  value: {{ $vaultAddr | quote }}
{{- $ext := .Values.externalVault | default dict }}
{{- $bundled := index .Values "triage-vault" }}
{{- if $bundled.enabled }}
{{- /* Bundled Vault: use token auth with dev root token */}}
- name: VAULT_KV_AUTH_METHOD
  value: "token"
- name: VAULT_KV_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-triage-vault-llm-keys" (include "triage-suggestion-service.fullname" .) }}
      key: vault-token
{{- else }}
{{- /* External Vault: use configured auth method */}}
- name: VAULT_KV_AUTH_METHOD
  value: {{ $ext.authMethod | default "kubernetes" | quote }}
{{- if eq ($ext.authMethod | default "kubernetes") "kubernetes" }}
- name: VAULT_KV_KUBERNETES_ROLE
  value: {{ $ext.role | default "triage-suggestion-service" | quote }}
{{- else }}
- name: VAULT_KV_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ $ext.tokenSecret | default "triage-vault-token" }}
      key: {{ $ext.tokenSecretKey | default "token" }}
{{- end }}
{{- end }}
{{- $mount := $ext.llmKeyMount | default "secret" }}
{{- $prefix := $ext.llmKeyPrefix | default "triage-suggestion-service/llm-keys" }}
- name: VAULT_KV_LLM_KEY_MOUNT
  value: {{ $mount | quote }}
- name: VAULT_KV_LLM_KEY_PREFIX
  value: {{ $prefix | quote }}
{{- $ttl := $ext.llmKeyTTL | default "" }}
{{- if $ttl }}
- name: VAULT_KV_LLM_KEY_TTL
  value: {{ $ttl | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Returns the name of the secret holding the EC P-256 private key.
Uses llmKeyEncryption.existingSecret when provided; otherwise falls back to the
auto-generated secret created by llm-key-encryption-secret.yaml.
*/}}
{{- define "triage-suggestion-service.llmKeyEncryptionSecretName" -}}
{{- $enc := .Values.llmKeyEncryption | default dict }}
{{- if $enc.existingSecret }}
{{- $enc.existingSecret }}
{{- else }}
{{- printf "%s-llm-key-encryption" (include "triage-suggestion-service.fullname" .) }}
{{- end }}
{{- end -}}

{{/*
LLM key encryption environment variables.
Injects ENCRYPTION_PRIVATE_KEY_FILE pointing to the mounted EC P-256 private key PEM file.
The key is either provided via llmKeyEncryption.existingSecret or auto-generated by the chart.
*/}}
{{- define "triage-suggestion-service.llmKeyEncryptionEnvVars" -}}
{{- $enc := .Values.llmKeyEncryption | default dict }}
- name: ENCRYPTION_PRIVATE_KEY_FILE
  value: "/secrets/llm-key-encryption/{{ $enc.secretKey | default "llm-key-private.pem" }}"
{{- end -}}

{{/*
LLM key encryption volume mounts.
Mounts the EC P-256 private key PEM (provided or auto-generated).
*/}}
{{- define "triage-suggestion-service.llmKeyEncryptionVolumeMounts" -}}
- name: llm-key-encryption
  mountPath: /secrets/llm-key-encryption
  readOnly: true
{{- end -}}

{{/*
LLM key encryption volumes.
Provides the EC P-256 private key PEM from a Kubernetes Secret.
*/}}
{{- define "triage-suggestion-service.llmKeyEncryptionVolumes" -}}
{{- $enc := .Values.llmKeyEncryption | default dict }}
- name: llm-key-encryption
  secret:
    secretName: {{ include "triage-suggestion-service.llmKeyEncryptionSecretName" . }}
    items:
    - key: {{ $enc.secretKey | default "llm-key-private.pem" }}
      path: {{ $enc.secretKey | default "llm-key-private.pem" }}
{{- end -}}

{{/*
Base URL for upload URL generation.
Returns the explicitly configured BASE_URL if set, otherwise computes the
internal Kubernetes service URL from the Helm fullname and HTTP port.
*/}}
{{- define "triage-suggestion-service.baseURL" -}}
{{- $env := .Values.deployment.environment | default dict }}
{{- if index $env "BASE_URL" }}
{{- index $env "BASE_URL" }}
{{- else }}
{{- $port := index $env "HTTP_PORT" | default "8080" }}
{{- printf "http://%s-api:%s" (include "triage-suggestion-service.fullname" .) (toString $port) }}
{{- end }}
{{- end -}}

{{/*
Pod securityContext for deployments.
On OpenShift, do not set runAsUser/runAsGroup/fsGroup by default so SCC can assign
allowed IDs. On non-OpenShift clusters, use configured values.
*/}}
{{- define "triage-suggestion-service.podSecurityContext" -}}
{{- if .Values.securityContext.enabled }}
securityContext:
  runAsNonRoot: true
  {{- if not (.Capabilities.APIVersions.Has "security.openshift.io/v1") }}
  {{- if .Values.securityContext.runAsUser }}
  runAsUser: {{ .Values.securityContext.runAsUser }}
  {{- end }}
  {{- if .Values.securityContext.runAsGroup }}
  runAsGroup: {{ .Values.securityContext.runAsGroup }}
  {{- end }}
  {{- if .Values.securityContext.fsGroup }}
  fsGroup: {{ .Values.securityContext.fsGroup }}
  {{- end }}
  {{- end }}
{{- end }}
{{- end -}}
