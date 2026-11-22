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
