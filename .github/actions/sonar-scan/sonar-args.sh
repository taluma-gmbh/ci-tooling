#!/usr/bin/env bash
# Berechnet Überspringen und Argumente des SonarScanners.
# Wird von .github/actions/sonar-scan/action.yml und von test/sonar-args.test.sh genutzt.

# should_scan <actor> <skip> <skip_actors>
# Bot-Absender bringen keine neuen Codeilen; deren Läufe scannen nicht.
should_scan() {
  local actor="$1" skip="$2" skip_actors="$3" entry
  if [ "$skip" = "true" ]; then
    return 1
  fi
  local IFS=','
  for entry in $skip_actors; do
    entry="${entry//[[:space:]]/}"
    if [ -n "$entry" ] && [ "$entry" = "$actor" ]; then
      return 1
    fi
  done
  return 0
}

# scope_args <event_name> <ref_name> <pr_number> <pr_head> <pr_base>
# Pull Requests werden als PR-Analyse gemeldet, alles andere als Branch-Analyse.
scope_args() {
  if [ "$1" = "pull_request" ]; then
    printf -- '-Dsonar.pullrequest.key=%s -Dsonar.pullrequest.branch=%s -Dsonar.pullrequest.base=%s' "$3" "$4" "$5"
  else
    printf -- '-Dsonar.branch.name=%s' "$2"
  fi
}

# scanner_args <event> <ref> <pr_number> <pr_head> <pr_base> <version> <timeout> <quality_gate_wait> <extra>
scanner_args() {
  local out
  out="$(scope_args "$1" "$2" "$3" "$4" "$5")"
  out="$out -Dsonar.ws.timeout=$7"
  if [ "$8" = "true" ]; then
    out="$out -Dsonar.qualitygate.wait=true"
  fi
  if [ -n "$6" ]; then
    out="$out -Dsonar.projectVersion=$6"
  fi
  if [ -n "$9" ]; then
    out="$out $9"
  fi
  printf '%s' "$out"
}

# require_token <token> — bricht ab, wenn ein Scan erwartet wird aber kein Token angekommen ist.
require_token() {
  if [ -z "$1" ]; then
    echo "::error::sonar-token ist leer. SONAR_TOKEN im aufrufenden Repo (oder als Org-Secret) hinterlegen."
    return 1
  fi
}
