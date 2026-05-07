{{- define "job-cronjob.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "job-cronjob.jobName" -}}
{{- printf "%s-%s" (include "job-cronjob.name" .) .Values.job.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "job-cronjob.cronjobName" -}}
{{- printf "%s-%s" (include "job-cronjob.name" .) .Values.cronjob.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "onelensdeployer.proxyEnv" -}}
{{- if or .Values.proxy.httpProxy .Values.proxy.httpsProxy .Values.proxy.noProxy }}
- name: HTTP_PROXY
  value: {{ .Values.proxy.httpProxy | quote }}
- name: http_proxy
  value: {{ .Values.proxy.httpProxy | quote }}
- name: HTTPS_PROXY
  value: {{ .Values.proxy.httpsProxy | quote }}
- name: https_proxy
  value: {{ .Values.proxy.httpsProxy | quote }}
- name: NO_PROXY
  value: {{ .Values.proxy.noProxy | quote }}
- name: no_proxy
  value: {{ .Values.proxy.noProxy | quote }}
{{- end }}
{{- end }}
