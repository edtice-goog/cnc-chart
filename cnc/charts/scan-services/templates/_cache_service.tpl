{{- define "storage_cache.env" }}
{{- if eq (index .Values .serviceName).storageProvider "minio" }}
- name: SPRING_PROFILES_ACTIVE
  value: {{ if eq .Values.mode "SRM" -}}"unify-minio"{{- else -}}"cnc-minio"{{- end }}
- name: MINIO_HOST
  value: {{ required "A valid Minio hostname entry is required." (index .Values .serviceName).minio.host | quote}}
- name: MINIO_PORT
  value: {{ required "A valid Minio port entry is required." (index .Values .serviceName).minio.port | quote}}
- name: MINIO_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ required "A valid Minio secret name must be provided with key root-user, root-password." (index .Values .serviceName).minio.secret | quote }}
      key: root-user
      optional: false
- name: MINIO_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ required "A valid Minio secret name must be provided with key root-user, root-password." (index .Values .serviceName).minio.secret | quote }}
      key: root-password
      optional: false
- name: MINIO_SECURE
  value: {{ (index .Values .serviceName).minio.secure | quote}}
- name: MINIO_CACERT
  value: {{ (index .Values .serviceName).minio.cacert | quote}}
- name: MINIO_VERIFY_HOSTNAME
  value: {{ (index .Values .serviceName).minio.verifyHostName | quote}}
{{- end }}
{{- if eq (index .Values .serviceName).storageProvider "aws" }}
- name: SPRING_PROFILES_ACTIVE
  value: {{ if eq .Values.mode "SRM" -}}"unify-aws"{{- else -}}"cnc-aws"{{- end }}
- name: AWS_REGION
  value: {{ required "A valid AWS region entry is required." (index .Values .serviceName).aws.region | quote}}
{{- if eq (index .Values .serviceName).aws.serviceAccount "" }}
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ required "A valid S3 secret name must be provided with key aws_access_key, aws_secret_key." (index .Values .serviceName).aws.secret | quote }}
      key: aws_access_key
      optional: false
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ required "A valid S3 secret name must be provided with key aws_access_key, aws_secret_key." (index .Values .serviceName).aws.secret | quote }}
      key: aws_secret_key
      optional: false
{{- end}}
- name: DIRECTORY_BUCKET_ENABLED
  value: {{ (index .Values .serviceName).aws.s3Express.enabled | quote}}
- name: DIRECTORY_BUCKET_TTL_DAYS
  value: {{ (index .Values .serviceName).aws.s3Express.ttlDays | quote}}
{{- end}}
{{- if eq (index .Values .serviceName).storageProvider "gcp" }}
- name: SPRING_PROFILES_ACTIVE
  value: {{ if eq .Values.mode "SRM" -}}"unify-gcp"{{- else -}}"cnc-gcp"{{- end }}
- name: GOOGLE_CLOUD_PROJECT
  value: {{ required "A valid GCP projectname entry is required." (index .Values .serviceName).gcp.project | quote}}
- name: GOOGLE_APPLICATION_CREDENTIALS
  value: /etc/gcp/key.json
{{- end}}
{{- if eq (index .Values .serviceName).storageProvider "azure" }}
- name: SPRING_PROFILES_ACTIVE
  value: {{ if eq .Values.mode "SRM" -}}"unify-azure"{{- else -}}"cnc-azure"{{- end }}
- name: AZURE_ENDPOINT
  valueFrom:
    secretKeyRef:
      name: {{ required "A valid Azure secret name must be provided with key azure_endpoint, azure_tenant_id, azure_account_key, azure_client_id, azure_client_secret, azure_subscription_id, azure_resource_group." (index .Values .serviceName).azure.secret | quote }}
      key: azure_endpoint
      optional: false
- name: AZURE_TENANT_ID
  valueFrom:
    secretKeyRef:
      name: {{ required "A valid Azure secret name must be provided with key azure_endpoint, azure_tenant_id, azure_account_key, azure_client_id, azure_client_secret, azure_subscription_id, azure_resource_group." (index .Values .serviceName).azure.secret | quote }}
      key: azure_tenant_id
      optional: false
- name: AZURE_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: {{ required "A valid Azure secret name must be provided with key azure_endpoint, azure_tenant_id, azure_account_key, azure_client_id, azure_client_secret, azure_subscription_id, azure_resource_group." (index .Values .serviceName).azure.secret | quote }}
      key: azure_client_id
      optional: false
- name: AZURE_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ required "A valid Azure secret name must be provided with key azure_endpoint, azure_tenant_id, azure_account_key, azure_client_id, azure_client_secret, azure_subscription_id, azure_resource_group." (index .Values .serviceName).azure.secret | quote }}
      key: azure_client_secret
      optional: false
- name: AZURE_SUBSCRIPTION_ID
  valueFrom:
    secretKeyRef:
      name: {{ required "A valid Azure secret name must be provided with key azure_endpoint, azure_tenant_id, azure_account_key, azure_client_id, azure_client_secret, azure_subscription_id, azure_resource_group." (index .Values .serviceName).azure.secret | quote }}
      key: azure_subscription_id
      optional: false
- name: AZURE_RESOURCE_GROUP
  valueFrom:
    secretKeyRef:
      name: {{ required "A valid Azure secret name must be provided with key azure_endpoint, azure_tenant_id, azure_account_key, azure_client_id, azure_client_secret, azure_subscription_id, azure_resource_group." (index .Values .serviceName).azure.secret | quote }}
      key: azure_resource_group
      optional: false
{{- end}}
{{- end }}

{{- define "redis_cache.env" }}
- name: REDIS_HOST
  value: {{ required "A valid redis hostname entry is required." ( (index .Values .serviceName).redis.host | default .Values.global.redis.host ) | quote}}
- name: REDIS_PORT
  value: {{ required "A valid redis port entry is required." ((index .Values .serviceName).redis.port | default .Values.global.redis.port) | quote}}
- name: REDIS_DATABASE
  value: {{ required "A valid redis database entry is required." (index .Values .serviceName).redis.database | quote}}
- name: REDIS_PASSWORD
  {{- if or (index .Values .serviceName).redis.authEnabled .Values.global.redis.authEnabled }}
  valueFrom:
    secretKeyRef:
      name: {{ required "A valid redis passwordSecret must be provided with key password." ((index .Values .serviceName).redis.passwordSecret | default .Values.global.redis.passwordSecret) | quote }}
      key: password
      optional: false
  {{- else }}
  value: ""
  {{- end}}
- name: REDIS_SECURE
  value: {{ (index .Values .serviceName).redis.secure | default .Values.global.redis.secure | quote}}
- name: REDIS_CACERT
{{- if or (index .Values .serviceName).redis.cacertSecret .Values.global.redis.cacertSecret }}
  value: /etc/redis/ssl/ca.crt
{{- else }}
  value: ""
{{- end}}
- name: REDIS_VERIFY_HOSTNAME
  value: {{ (index .Values .serviceName).redis.verifyHostName | default .Values.global.redis.verifyHostName | quote}}
{{- end }}