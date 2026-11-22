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

# project_key <datei> — liest sonar.projectKey aus sonar-project.properties.
# Die CE-Endpunkte nehmen component (Projekt-Key), nicht den Ordnerpfad; ohne Key ist die
# CE-Freigabe nicht möglich.
project_key() {
  local file="${1:-sonar-project.properties}"
  [ -f "$file" ] || return 1
  awk -F= 'BEGIN { FS = "=" }
           /^[[:space:]]*sonar\.projectKey[[:space:]]*=/ {
             sub(/^[^=]*=/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }' "$file"
}

# ce_slot_free <queue_laenge> <current_status>
# Der Compute Engine arbeitet Berichte pro Projekt sequentiell ab und verwirft Berichte, deren
# Analyse-Datum älter ist als das des zuletzt gespeicherten. Zwei Scans desselben Projekts, die in
# vertauschter Reihenfolge submitet werden, produzieren genau diesen Fehler — die Plugin-Phase
# schwankt zwischen Sekunden und Minuten. Frei ist der Slot, wenn die Queue leer ist und kein
# nicht-terminaler Task läuft. Unlesbare Eingaben entscheiden für den Scan: der Retry greift später.
ce_slot_free() {
  local queue_len="${1:-0}" current="${2:-}"
  queue_len="${queue_len//[[:space:]]/}"
  case "$queue_len" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ "$queue_len" != "0" ]; then
    return 1
  fi
  case "$current" in
    ''|SUCCESS|FAILED) return 0 ;;
    *) return 1 ;;
  esac
}

# retryable_report_failure <meldung>
# Nur die Datums-Kollision rechtfertigt einen sofortigen Wiederholungsversuch: der zweite Anlauf
# submitet später und ist damit gegen dem Konkurrenten chronologisch korrekt. Plugin-Timeout und
# Quality-Gate-Verletzung würden durch einen blinden Retry nur verdoppelt.
retryable_report_failure() {
  printf '%s' "${1:-}" | grep -qiE 'Date of analysis cannot be older'
}

# already_scanned <letztes_submitted_at> <run_started_at> <run_attempt>
# Doppelarbeit statt Abbruch: wurde für diesen Branch bereits ein Bericht erfolgreich abgegeben,
# nachdem dieser Lauf gestartet ist, ist der Scan überflüssig. github.run_started_at bleibt bei
# einem erneuten Lauf desselben Workflows stehen; run_attempt > 1 ist daher ein ausdrücklicher
# Auftrag, erneut zu scannen, und wird nie übersprungen. Unlesbare Zeitstempel entscheiden
# zugunsten des Scans.
already_scanned() {
  local last="${1:-}" started="${2:-}" attempt="${3:-1}" last_epoch started_epoch
  [ "$attempt" = "1" ] || return 1
  [ -n "$last" ] && [ -n "$started" ] || return 1
  last_epoch=$(date -d "$last" +%s 2>/dev/null) || return 1
  started_epoch=$(date -d "$started" +%s 2>/dev/null) || return 1
  [ "$last_epoch" -ge "$started_epoch" ]
}

# ce_get <token> <host_url> <pfad> <antwortdatei> [weitere curl-Argumente]
# Liest einen JSON-Body in die Antwortdatei. Fehlender Zugriff bricht den Lauf nicht, sondern
# warnt: ohne Leserecht auf die Compute-Engine bleiben CE-Gate und Doppel-Scan-Erkennung
# wirkungslos, der Scan selbst läuft trotzdem.
ce_get() {
  local token="$1" host="$2" path="$3" file="$4"
  shift 4
  local code
  code=$(curl -sS --max-time 20 -u "${token}:" -o "$file" --write-out '%{http_code}' \
    --get "${host}${path}" "$@" 2>/dev/null) || code="000"
  case "$code" in
    2??) return 0 ;;
    401|403)
      echo "::warning::SonarQube antwortet mit ${code} auf ${path}. Das Token darf die Compute-Engine nicht lesen; CE-Gate und Doppel-Scan-Erkennung sind dadurch wirkungslos."
      return 1 ;;
    *)
      echo "::warning::SonarQube antwortet nicht auf ${path} (HTTP ${code}); CE-Gate und Doppel-Scan-Erkennung sind dadurch wirkungslos."
      return 1 ;;
  esac
}

# scan_needs_report <erster_outcome> <retry_noetig> <zweiter_outcome>
# 0 = der Lauf soll fehlschlagen. Der Scanner läuft mit continue-on-error, sonst könnte ein
# erfolgreicher zweiter Versuch den Lauf nicht mehr grün machen; die Bewertung übernimmt
# scan_needs_report. Nach einer Datums-Kollision zählt ausschließlich der zweite Versuch.
scan_needs_report() {
  local first="$1" retry="$2" second="$3"
  if [ "$retry" = "true" ]; then
    if [ "$second" = "success" ]; then
      return 1
    fi
    return 0
  fi
  if [ "$first" = "failure" ]; then
    return 0
  fi
  return 1
}
