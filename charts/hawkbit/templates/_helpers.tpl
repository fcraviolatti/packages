{{- define "hawkbit.name" -}}
hawkbit
{{- end -}}

{{- define "hawkbit.simpleui.name" -}}
hawkbit-simple-ui
{{- end -}}

{{- define "hawkbit.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "hawkbit.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "hawkbit.simpleui.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "hawkbit.simpleui.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}


{{- define "hawkbit.chart" -}}
{{ .Chart.Name }}-{{ .Chart.Version }}
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
