{{/*
This template validates the chart values and fails early if required values are missing or invalid.
Include this in a pre-install/pre-upgrade hook to catch configuration errors before deployment.
*/}}
{{- include "vnext.validateValues" . -}}

