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
  # Socket-Timeout gegen SonarWeb. Der Scanner liest ihn aus sonar.scanner.socketTimeout; das
  # ältere sonar.ws.timeout ist davon nur der Fallback und meldet bei jedem Lauf eine
  # Deprecation-Warnung. Beide werden von derselben Stelle in Sekunden geparst
  # (sonar-scanner-java-library, HttpConfig.loadDuration), der Wert ist also identisch.
  out="$out -Dsonar.scanner.socketTimeout=${SONAR_TIMEOUT:-180}"
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

# scanner_words <argumentkette> — ein Argument pro Zeile, Anführungszeichen fassen Werte mit
# Leerzeichen zusammen. Der maven-Zweig liest die Zeilen in ein Feld und übergibt sie als einzelne
# Argumente; eine reine Leerzeichen-Zerlegung würde «-Dsonar.projectName="E-Rechnung Service"»
# in zwei Argumente teilen und stillschweigend ein abgeschnittenes Projekt erzeugen.
scanner_words() {
  [ -n "${1//[[:space:]]/}" ] || return 0
  printf '%s' "$1" | xargs -r -n1 printf '%s\n'
}

# scanner_mode <scanner> — normalisiert die Scanner-Art; unbekannte Werte sind ein Konfigurationsfehler.
# Der Modus wählt ausschließlich den Aufruf, die Argumente bleiben dieselben. maven ist für
# Projekte, deren Analyse den Classpath des Builds braucht (Java/Maven): die Standalone-CLI sieht
# ihn nicht und schaltet Java-Regeln still ab, das Gate bleibt grün.
# Die Fehlermeldung geht nach stderr, damit sie ein Aufrufer mit $(scanner_mode ...) nicht einfängt.
scanner_mode() {
  case "$1" in
    ''|cli) printf 'cli' ;;
    maven) printf 'maven' ;;
    *)
      echo "::error::scanner muss cli oder maven sein, erhalten: $1" >&2
      return 1
      ;;
  esac
}

# maven_scan <argumentkette> — ruft den SonarScanner über den sonar-maven-Plugin des Projekts auf,
# im aktuellen Verzeichnis (dem project-dir des Schritts). Der Classpath kommt aus dem Build, den
# das Projekt selbst ausgeführt hat; die Standalone-CLI kennt ihn nicht.
# Token und Host bleiben auf der Umgebung des Schritts beschränkt: der Plugin liest SONAR_TOKEN und
# SONAR_HOST_URL dort, und ein -Dsonar.token im Kommando wäre im Prozessverzeichnis des Runners zu
# lesen — dasselbe Argument, das den npm-Scanner aus erechnung-client vertrieben hat.
# Die Plugin-Version steht im pom unter <build><plugins>, nicht auf der Kommandozeile, damit
# Renovates Maven-Manager sie findet.
maven_scan() {
  local -a args=()
  mapfile -t args < <(scanner_words "$1")
  mvn -B sonar:sonar "${args[@]}"
}

# require_token <token> — bricht ab, wenn ein Scan erwartet wird aber kein Token angekommen ist.
require_token() {
  if [ -z "$1" ]; then
    echo "::error::sonar-token ist leer. SONAR_TOKEN im aufrufenden Repo (oder als Org-Secret) hinterlegen."
    return 1
  fi
}

