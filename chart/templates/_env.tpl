{{/*
Environment for the misp-core container. Non-sensitive settings inline; secrets
via secretKeyRef. The huge set of optional MISP env (auth OIDC/LDAP/AAD, S3, proxy,
sync, PHP tuning) is left to extraEnv / extraEnvFrom.
*/}}
{{- define "misp.coreEnv" -}}
- name: BASE_URL
  value: {{ required "config.baseUrl is required (public MISP URL)" .Values.config.baseUrl | quote }}
- name: TZ
  value: {{ .Values.config.timezone | quote }}
- name: ENABLE_BACKGROUND_UPDATES
  value: {{ .Values.config.enableBackgroundUpdates | quote }}
# --- Database ---
- name: MYSQL_HOST
  value: {{ include "misp.mariadb.fullname" . | quote }}
- name: MYSQL_PORT
  value: "3306"
- name: MYSQL_USER
  value: {{ .Values.mariadb.username | quote }}
- name: MYSQL_DATABASE
  value: {{ .Values.mariadb.database | quote }}
- name: MYSQL_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "misp.secretName" . }}
      key: mysql-password
# --- Redis ---
- name: REDIS_HOST
  value: {{ include "misp.redis.host" . | quote }}
- name: REDIS_PORT
  value: {{ .Values.externalRedis.port | default 6379 | quote }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "misp.redis.secretName" . }}
      key: {{ include "misp.redis.secretKey" . }}
# --- Initial admin / org ---
- name: ADMIN_EMAIL
  value: {{ .Values.config.adminEmail | quote }}
- name: ADMIN_ORG
  value: {{ .Values.config.adminOrg | quote }}
- name: ADMIN_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "misp.secretName" . }}
      key: admin-password
- name: ADMIN_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "misp.secretName" . }}
      key: admin-key
# --- Crypto ---
- name: GPG_PASSPHRASE
  valueFrom:
    secretKeyRef:
      name: {{ include "misp.secretName" . }}
      key: gpg-passphrase
- name: ENCRYPTION_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "misp.secretName" . }}
      key: encryption-key
- name: SALT
  valueFrom:
    secretKeyRef:
      name: {{ include "misp.secretName" . }}
      key: salt
{{- if .Values.mail.enabled }}
- name: SMTP_FQDN
  value: {{ include "misp.mail.fullname" . | quote }}
- name: SMTP_PORT
  value: "25"
{{- end }}
{{- with .Values.config.extraEnv }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end }}

{{/* envFrom for misp-core (optional Secrets/ConfigMaps: OIDC/LDAP/AAD/S3/proxy/sync). */}}
{{- define "misp.coreEnvFrom" -}}
{{- with .Values.config.extraEnvFrom }}
envFrom:
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end }}
