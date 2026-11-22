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

# quality_gate_blocks <event_name> <ref_name> <policy> <blocking_refs>
# Policy auto: blockieren nur bei Pull Requests und bei Refs aus blocking_refs.
# Vorschau-Branches analysieren ohne Gate-Wait, ihre New-Code-Baseline ist nach Merges
# aus main nicht belastbar; main und PR-Analyse haben sie.
quality_gate_blocks() {
  local entry
  case "$3" in
    block) return 0 ;;
    off) return 1 ;;
  esac
  if [ "$1" = "pull_request" ]; then
    return 0
  fi
  local IFS=','
  for entry in $4; do
    entry="${entry//[[:space:]]/}"
    if [ -n "$entry" ] && [ "$entry" = "$2" ]; then
      return 0
    fi
  done
  return 1
}

# scope_args <event_name> <branch_name> <pr_number> <pr_head> <pr_base>
# Pull Requests werden als PR-Analyse gemeldet, alles andere als Branch-Analyse.
scope_args() {
  if [ "$1" = "pull_request" ]; then
    printf -- '-Dsonar.pullrequest.key=%s -Dsonar.pullrequest.branch=%s -Dsonar.pullrequest.base=%s' "$3" "$4" "$5"
  else
    printf -- '-Dsonar.branch.name=%s' "$2"
  fi
}

# scanner_args liest die Konfiguration aus Umgebungsvariablen:
#   SONAR_EVENT, SONAR_BRANCH, SONAR_PR_NUMBER, SONAR_PR_HEAD, SONAR_PR_BASE,
#   SONAR_VERSION, SONAR_TIMEOUT, SONAR_GATE_WAIT, SONAR_REFERENCE_BRANCH, SONAR_EXTRA_ARGS
# Branch-Analysen brauchen sonar.newCode.referenceBranch: ohne Referenz fällt SonarQube auf die
# instanzweit letzte gemeldete Projektversion zurück (PREVIOUS_VERSION), und dann gilt alter Code
# aus main als neuer Code des Vorschau-Branches. Pull Requests bringen die Referenz über
# sonar.pullrequest.base.
# Der Property-Name ist sonar.newCode.referenceBranch, nicht sonar.referenceBranch. Verifiziert an
# SonarQube 26.10: mit sonar.referenceBranch bleibt die New-Code-Definition des Branches
# unverändert PREVIOUS_VERSION (inherited=true), mit sonar.newCode.referenceBranch steht sie auf
# REFERENCE_BRANCH/main und die Branch-Analyse meldet keine new_coverage-Bedingung mehr.
scanner_args() {
  local event="${SONAR_EVENT:-}" branch="${SONAR_BRANCH:-}" out
  out="$(scope_args "$event" "$branch" "${SONAR_PR_NUMBER:-}" "${SONAR_PR_HEAD:-}" "${SONAR_PR_BASE:-}")"
  out="$out -Dsonar.ws.timeout=${SONAR_TIMEOUT:-180}"
  if [ "${SONAR_GATE_WAIT:-}" = "true" ]; then
    out="$out -Dsonar.qualitygate.wait=true"
  fi
  if [ "$event" != "pull_request" ] && [ -n "${SONAR_REFERENCE_BRANCH:-}" ] \
    && [ "$SONAR_REFERENCE_BRANCH" != "$branch" ]; then
    out="$out -Dsonar.newCode.referenceBranch=$SONAR_REFERENCE_BRANCH"
  fi
  if [ -n "${SONAR_VERSION:-}" ]; then
    out="$out -Dsonar.projectVersion=$SONAR_VERSION"
  fi
  if [ -n "${SONAR_EXTRA_ARGS:-}" ]; then
    out="$out $SONAR_EXTRA_ARGS"
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

