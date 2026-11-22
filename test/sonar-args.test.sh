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

check "Renovate-Lauf scannt nicht" false "$(bool 'renovate[bot]' 'false' 'renovate[bot],dependabot[bot]')"
check "Dependabot-Lauf scannt nicht" false "$(bool 'dependabot[bot]' 'false' 'renovate[bot], dependabot[bot]')"
check "Menschlicher Lauf scannt" true "$(bool 'jcnk9' 'false' 'renovate[bot],dependabot[bot]')"
check "skip=true unterdrückt" false "$(bool 'jcnk9' 'true' 'renovate[bot]')"
check "leere skip-Liste scannt" true "$(bool 'renovate[bot]' 'false' '')"

check "Branch-Analyse" \
  "-Dsonar.branch.name=main -Dsonar.ws.timeout=180 -Dsonar.qualitygate.wait=true" \
  "$(scanner_args push main '' '' '' '' 180 true '')"

check "PR-Analyse" \
  "-Dsonar.pullrequest.key=42 -Dsonar.pullrequest.branch=renovate/x -Dsonar.pullrequest.base=main -Dsonar.ws.timeout=180 -Dsonar.qualitygate.wait=true" \
  "$(scanner_args pull_request renovate/x 42 renovate/x main '' 180 true '')"

check "Version und Extra-Argumente" \
  "-Dsonar.branch.name=main -Dsonar.ws.timeout=180 -Dsonar.qualitygate.wait=true -Dsonar.projectVersion=1.2.3 -Dsonar.language=php" \
  "$(scanner_args push main '' '' '' 1.2.3 180 true '-Dsonar.language=php')"

check "Timeout überschreibbar, Gate-Wait aus" \
  "-Dsonar.branch.name=main -Dsonar.ws.timeout=30" \
  "$(scanner_args push main '' '' '' '' 30 false '')"

gate() {
  if quality_gate_blocks "$1" "$2" "$3" "$4"; then echo true; else echo false; fi
}

check "auto: Pull Request blockiert" true "$(gate pull_request renovate/x auto main)"
check "auto: main blockiert" true "$(gate push main auto main)"
check "auto: Vorschau-Branch blockiert nicht" false "$(gate push feat/x auto main)"
check "auto: weitere blockierende Refs" true "$(gate push develop auto 'main, develop')"
check "auto: ohne blockierende Refs blockiert kein Push" false "$(gate push main auto '')"
check "block wartet auch auf Vorschau-Branches" true "$(gate push feat/x block main)"
check "off wartet nirgends" false "$(gate pull_request renovate/x off main)"
check "unbekannte Policy folgt auto" false "$(gate push feat/x ungültig main)"

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
