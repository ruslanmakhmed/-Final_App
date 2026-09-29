{{/* Общие метки. component = app | db — по ним Prometheus отбирает поды приложения. */}}
{{- define "shortlink.labels" -}}
app.kubernetes.io/name: shortlink
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "shortlink.selector" -}}
app.kubernetes.io/name: shortlink
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "shortlink.dbName" -}}
{{ .Release.Name }}-db
{{- end -}}
