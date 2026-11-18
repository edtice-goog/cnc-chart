{{- define "connect.keystore.path" -}}
/coverity/config/keystore.jks
{{- end -}}

{{- define "connect.keystore.alias" -}}
privatekey
{{- end -}}

{{- define "connect.truststore.path" -}}
/coverity/config/truststore.jks
{{- end -}}


{{- define "connect.tls.cert.path" -}}
/config/cim/cert/tls.crt
{{- end -}}

{{- define "connect.tls.key.path" -}}
/config/cim/cert/tls.key
{{- end -}}

{{- define "connect.secret.keystore.path" -}}
/coverity/config/secretKeystore.keystore
{{- end -}}

{{- define "cnc.cim.setRunAsUserId" -}}
{{- $containerName := . -}}
{{- if eq $containerName "cnc-crossbar" -}}
runAsUser: 242
{{- else if or (eq $containerName "cnc-temporal-service") (eq $containerName "temporal-admin-tools") -}}
runAsUser: 1000
{{- else if eq $containerName "pgpool" -}}
runAsUser: 1001
{{- else }}
runAsUser: 5000
{{- end -}}
{{- end -}}

{{- define "cnc.cim.setReadOnlyFileSystem" -}}
readOnlyRootFilesystem: true
{{- end -}}

