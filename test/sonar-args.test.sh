#!/usr/bin/env bash
# Testet die Argument-Berechnung des Sonar-Scan-Wrappers.
# Aufruf: bash test/sonar-args.test.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
# shellcheck source=.github/actions/sonar-scan/sonar-args.sh
source .github/actions/sonar-scan/sonar-args.sh

failures=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   - $name"
  else
    echo "FAIL - $name"
    echo "       erwartet: $expected"
    echo "       erhalten: $actual"
    failures=$((failures + 1))
  fi
}

bool() {
  if should_scan "$1" "$2" "$3"; then echo true; else echo false; fi
}

gate() {
  if quality_gate_blocks "$1" "$2" "$3" "$4"; then echo true; else echo false; fi
}

# args_for <event> <branch> <pr_number> <pr_head> <pr_base> <version> <timeout> <gate_wait> <reference_branch> <extra>
args_for() {
  SONAR_EVENT="$1" SONAR_BRANCH="$2" SONAR_PR_NUMBER="$3" SONAR_PR_HEAD="$4" SONAR_PR_BASE="$5" \
    SONAR_VERSION="$6" SONAR_TIMEOUT="$7" SONAR_GATE_WAIT="$8" SONAR_REFERENCE_BRANCH="$9" \
    SONAR_EXTRA_ARGS="${10:-}" scanner_args
}

check "Renovate-Lauf scannt nicht" false "$(bool 'renovate[bot]' 'false' 'renovate[bot],dependabot[bot]')"
check "Dependabot-Lauf scannt nicht" false "$(bool 'dependabot[bot]' 'false' 'renovate[bot], dependabot[bot]')"
check "Menschlicher Lauf scannt" true "$(bool 'jcnk9' 'false' 'renovate[bot],dependabot[bot]')"
check "skip=true unterdrückt" false "$(bool 'jcnk9' 'true' 'renovate[bot]')"
check "leere skip-Liste scannt" true "$(bool 'renovate[bot]' 'false' '')"

check "auto: Pull Request blockiert" true "$(gate pull_request renovate/x auto main)"
check "auto: main blockiert" true "$(gate push main auto main)"
check "auto: Vorschau-Branch blockiert nicht" false "$(gate push feat/x auto main)"
check "auto: weitere blockierende Refs" true "$(gate push develop auto 'main, develop')"
check "auto: ohne blockierende Refs blockiert kein Push" false "$(gate push main auto '')"
check "block wartet auch auf Vorschau-Branches" true "$(gate push feat/x block main)"
check "off wartet nirgends" false "$(gate pull_request renovate/x off main)"
check "unbekannte Policy folgt auto" false "$(gate push feat/x ungültig main)"

check "Branch-Analyse ohne Referenz" \
  "-Dsonar.branch.name=preview-42 -Dsonar.ws.timeout=180" \
  "$(args_for push preview-42 '' '' '' '' 180 false '' '')"

check "Branch-Analyse mit Referenz" \
  "-Dsonar.branch.name=preview-42 -Dsonar.ws.timeout=180 -Dsonar.newCode.referenceBranch=main" \
  "$(args_for push preview-42 '' '' '' '' 180 false main '')"

check "main bekommt keine eigene Referenz" \
  "-Dsonar.branch.name=main -Dsonar.ws.timeout=180 -Dsonar.qualitygate.wait=true" \
  "$(args_for push main '' '' '' '' 180 true main '')"

check "PR-Analyse nutzt pullrequest.base statt Referenz" \
  "-Dsonar.pullrequest.key=42 -Dsonar.pullrequest.branch=renovate/x -Dsonar.pullrequest.base=main -Dsonar.ws.timeout=180 -Dsonar.qualitygate.wait=true" \
  "$(args_for pull_request renovate/x 42 renovate/x main '' 180 true main '')"

check "Version, Timeout, Referenz und Extra-Argumente" \
  "-Dsonar.branch.name=feat/x -Dsonar.ws.timeout=90 -Dsonar.newCode.referenceBranch=main -Dsonar.projectVersion=1.2.3 -Dsonar.language=php" \
  "$(args_for push feat/x '' '' '' 1.2.3 90 false main '-Dsonar.language=php')"

# project_key liest den Key aus der Properties-Datei; die CE-Endpunkte brauchen ihn.
key_dir=$(mktemp -d)
printf 'sonar.projectKey=portfolio-companion\nsonar.sources=src\n' > "$key_dir/sonar-project.properties"
check "project_key aus sonar-project.properties" "portfolio-companion" "$(project_key "$key_dir/sonar-project.properties")"
printf 'sonar.projectKey = mein-key  \n' > "$key_dir/with-spaces.properties"
check "project_key ohne Leerzeichen" "mein-key" "$(project_key "$key_dir/with-spaces.properties")"
check "project_key ohne Datei ist leer" "leer" "$(project_key "$key_dir/unbekannt.properties" >/dev/null 2>&1 && echo vorhan || echo leer)"
rm -rf "$key_dir"

# ce_slot_free <queue> <current_status>
ce() {
  if ce_slot_free "$1" "$2"; then echo true; else echo false; fi
}
check "CE frei bei leerer Queue ohne aktuellen Task" true "$(ce 0 '')"
check "CE frei bei abgeschlossenem aktuellen Task" true "$(ce 0 SUCCESS)"
check "CE belegt bei laufendem Task" false "$(ce 0 PENDING)"
check "CE belegt bei wartendem Task" false "$(ce 0 IN_PROGRESS)"
check "CE belegt bei Einträgen in der Queue" false "$(ce 2 '')"
check "CE frei bei unlesbarer Queue (Scan gewinnt)" true "$(ce 'x' '')"

# retryable_report_failure <meldung>
retry() {
  if retryable_report_failure "$1"; then echo true; else echo false; fi
}
check "Datums-Kollision ist wiederholbar" true "$(retry 'Validation of project failed: o Date of analysis cannot be older than the date of the last known analysis on this project.')"
check "Plugin-Timeout ist nicht wiederholbar" false "$(retry 'java.net.SocketTimeoutException: timeout')"
check "Leere Meldung ist nicht wiederholbar" false "$(retry '')"

# already_scanned <letztes_submitted_at> <run_started_at> [run_attempt]
scanned() {
  if already_scanned "$1" "$2" "${3:-1}"; then echo true; else echo false; fi
}
check "Bericht nach Laufbeginn ueberspringt" true "$(scanned '2026-11-22T10:56:23+0000' '2026-11-22T10:54:31Z')"
check "Bericht vor Laufbeginn scannt" false "$(scanned '2026-11-22T10:50:00+0000' '2026-11-22T10:54:31Z')"
check "Gleiche Zeit ueberspringt" true "$(scanned '2026-11-22T10:54:31+0000' '2026-11-22T10:54:31Z')"
check "Ohne Bericht wird gescannt" false "$(scanned '' '2026-11-22T10:54:31Z')"
check "Ohne Laufstart wird gescannt" false "$(scanned '2026-11-22T10:56:23+0000' '')"
check "Unlesbarer Zeitstempel scannt" false "$(scanned 'vorher' '2026-11-22T10:54:31Z')"
check "Erneuter Lauf scannt trotz Bericht" false "$(scanned '2026-11-22T10:56:23+0000' '2026-11-22T10:54:31Z' 2)"
check "Erster Versuch kann ueberspringen" true "$(scanned '2026-11-22T10:56:23+0000' '2026-11-22T10:54:31Z' 1)"

# scan_needs_report <erster_outcome> <retry_noetig> <zweiter_outcome>
report() {
  if scan_needs_report "$1" "$2" "$3"; then echo rot; else echo gruen; fi
}
check "Fehlgeschlagener Scan ohne Retry wird rot" rot "$(report failure false skipped)"
check "Erfolgreicher Scan bleibt gruen" gruen "$(report success false skipped)"
check "Uebersprungener Scan bleibt gruen" gruen "$(report skipped false skipped)"
check "Erfolgreiche Wiederholung wird gruen" gruen "$(report failure true success)"
check "Fehlgeschlagene Wiederholung bleibt rot" rot "$(report failure true failure)"
check "Ausbleibende Wiederholung bleibt rot" rot "$(report failure true skipped)"

if require_token "" >/dev/null 2>&1; then
  check "leerer Token bricht ab" fail ok
else
  check "leerer Token bricht ab" ok ok
fi
if require_token "squ_xxx" >/dev/null 2>&1; then
  check "gesetzter Token erlaubt" ok ok
else
  check "gesetzter Token erlaubt" fail ok
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures Test(s) fehlgeschlagen"
  exit 1
fi
echo "alle Tests bestanden"
