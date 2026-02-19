{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "hawkbit.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{/*
Expand the name of the chart.
*/}}
{{- define "hawkbit.name" -}}
hawkbit
{{- end -}}

{{- define "hawkbit.simpleui.name" -}}
hawkbit-simple-ui
{{- end -}}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "hawkbit.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "hawkbit.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "hawkbit.simpleui.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "hawkbit.simpleui.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Chart label.
*/}}
{{- define "hawkbit.chart" -}}
{{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
Common labels
*/}}
{{- define "hawkbit.labels" -}}
app.kubernetes.io/name: {{ include "hawkbit.name" . }}
helm.sh/chart: {{ include "hawkbit.chart" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Return the appropriate apiVersion for ingress.
*/}}
{{- define "hawkbit.ingressAPIVersion" -}}
{{- if .Capabilities.APIVersions.Has "networking.k8s.io/v1/Ingress" -}}
{{- print "networking.k8s.io/v1" -}}
{{- else -}}
{{- print "networking.k8s.io/v1beta1" -}}
{{- end -}}
{{- end -}}
