{{- define "faceapp.fullname" -}}
{{- .Release.Name -}}
{{- end -}}

{{- define "faceapp.labels" -}}
app.kubernetes.io/name: {{ include "faceapp.fullname" . }}
{{- end -}}

{{- define "faceapp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "faceapp.fullname" . }}
{{- end -}}
