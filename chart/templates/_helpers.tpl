{{- define "misp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "misp.fullname" -}}
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

{{- define "misp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "misp.labels" -}}
helm.sh/chart: {{ include "misp.chart" . }}
{{ include "misp.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: misp
{{- end }}

{{- define "misp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "misp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "misp.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "misp.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Chart-managed secret holding all generated MISP secrets. */}}
{{- define "misp.secretName" -}}
{{- if .Values.config.existingSecret -}}
{{- .Values.config.existingSecret -}}
{{- else -}}
{{- printf "%s-secret" (include "misp.fullname" .) -}}
{{- end -}}
{{- end }}

{{/* Component names. */}}
{{- define "misp.core.fullname" -}}{{ printf "%s-core" (include "misp.fullname" .) }}{{- end }}
{{- define "misp.nginx.fullname" -}}{{ printf "%s-nginx" (include "misp.fullname" .) }}{{- end }}
{{- define "misp.mariadb.fullname" -}}{{ printf "%s-mariadb" (include "misp.fullname" .) }}{{- end }}
{{- define "misp.mail.fullname" -}}{{ printf "%s-mail" (include "misp.fullname" .) }}{{- end }}
{{- define "misp.guard.fullname" -}}{{ printf "%s-guard" (include "misp.fullname" .) }}{{- end }}

{{/* misp-modules service name. Defaults to "misp-modules" because the misp-core
     image defaults the enrichment URL to http://misp-modules:6666. Overridable. */}}
{{- define "misp.modules.fullname" -}}
{{- default "misp-modules" .Values.modules.serviceName -}}
{{- end }}

{{/* Redis host (CloudPirates subchart => <release>-redis). */}}
{{- define "misp.redis.host" -}}
{{- if .Values.externalRedis.host -}}{{ .Values.externalRedis.host }}{{- else -}}{{ printf "%s-redis" .Release.Name }}{{- end -}}
{{- end }}

{{/* Secret + key holding the Redis password. CloudPirates redis generates one in
     <release>-redis (key redis-password); external Redis uses externalRedis.*. */}}
{{- define "misp.redis.secretName" -}}
{{- if .Values.externalRedis.host -}}{{ required "externalRedis.existingSecret required for external Redis" .Values.externalRedis.existingSecret }}{{- else -}}{{ printf "%s-redis" .Release.Name }}{{- end -}}
{{- end }}
{{- define "misp.redis.secretKey" -}}
{{- if .Values.externalRedis.host -}}{{ .Values.externalRedis.existingSecretPasswordKey | default "redis-password" }}{{- else -}}redis-password{{- end -}}
{{- end }}

{{/* Image ref helper: dict {img:{repository,tag,digest}, root}. */}}
{{- define "misp.image" -}}
{{- $img := .img -}}
{{- $reg := .root.Values.image.registry -}}
{{- $ref := $img.repository -}}
{{- if $reg -}}{{- $ref = printf "%s/%s" $reg $img.repository -}}{{- end -}}
{{- if $img.digest -}}
{{- printf "%s@%s" $ref $img.digest -}}
{{- else -}}
{{- printf "%s:%s" $ref ($img.tag | default .root.Chart.AppVersion) -}}
{{- end -}}
{{- end }}

{{/* MISP URL used by the bootstrap Job (in-cluster misp-nginx Service by default,
     https when nginx.tls.enabled; self-signed cert, verification off unless
     bootstrap.verifyTls). */}}
{{- define "misp.bootstrap.url" -}}
{{- if .Values.bootstrap.url -}}
{{- .Values.bootstrap.url | trimSuffix "/" -}}
{{- else -}}
{{- if .Values.nginx.tls.enabled -}}
{{- printf "https://%s:%v" (include "misp.nginx.fullname" .) .Values.nginx.service.httpsPort -}}
{{- else -}}
{{- printf "http://%s:%v" (include "misp.nginx.fullname" .) .Values.nginx.service.httpPort -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/* Pod spec shared by the bootstrap Job and the feeds-fetch CronJob.
     dict {root, mode}. Pods carry the chart selector labels so the chart
     NetworkPolicy lets them reach misp-core. */}}
{{- define "misp.bootstrap.podSpec" -}}
{{- $root := .root -}}
{{- $b := $root.Values.bootstrap -}}
serviceAccountName: {{ include "misp.serviceAccountName" $root }}
automountServiceAccountToken: false
{{- with $root.Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
securityContext:
  runAsNonRoot: true
  runAsUser: 65534
  runAsGroup: 65534
  seccompProfile:
    type: RuntimeDefault
containers:
  - name: bootstrap
    image: {{ include "misp.image" (dict "img" $b.image "root" $root) | quote }}
    imagePullPolicy: {{ $root.Values.image.pullPolicy }}
    command: ["python3", "-I", "/bootstrap/bootstrap.py"]
    env:
      - name: MODE
        value: {{ .mode | quote }}
      - name: MISP_URL
        value: {{ include "misp.bootstrap.url" $root | quote }}
      - name: MISP_VERIFY_TLS
        value: {{ $b.verifyTls | quote }}
      - name: WAIT_TIMEOUT
        value: {{ $b.waitTimeoutSeconds | quote }}
      - name: BOOTSTRAP_CONFIG
        value: /bootstrap/config.json
      - name: PYTHONDONTWRITEBYTECODE
        value: "1"
      - name: MISP_KEY
        valueFrom:
          secretKeyRef:
            name: {{ include "misp.secretName" $root }}
            key: admin-key
    securityContext:
      allowPrivilegeEscalation: false
      privileged: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
          - ALL
    {{- with $b.resources }}
    resources:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    volumeMounts:
      - name: bootstrap
        mountPath: /bootstrap
        readOnly: true
volumes:
  - name: bootstrap
    configMap:
      name: {{ printf "%s-bootstrap" (include "misp.fullname" $root) }}
{{- end }}
