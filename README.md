# ci-tooling

Wiederverwendbare GitHub-Actions für Pipelines in `taluma-gmbh`. Ein Ort für Scan- und
Build-Schritte, die sonst in jedem Repo gleich dupliziert werden.

## Enthaltene Actions

| Action | Zweck |
| --- | --- |
| `.github/actions/sonar-scan` | SonarQube-Scan mit Bot-Auslassung, Branch-/PR-Erkennung, Scanner-Cache und gesetzten Timeout-Defaults |

## Nutzung

`.github/workflows/ci.yml` im Verbraucherrepositorium:

```yaml
jobs:
  quality:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0

      - name: SonarQube-Scan
        uses: taluma-gmbh/ci-tooling/.github/actions/sonar-scan@v1
        with:
          sonar-token: ${{ secrets.SONAR_TOKEN }}
          sonar-host-url: ${{ vars.SONAR_HOST_URL }}
          project-version: ${{ steps.version.outputs.version }}
          args: -Dsonar.sources=src
```

`sonar-token` und `sonar-host-url` sind Pflicht. Beide bleiben im Verbraucherrepos stehen, als
Org-Secret `SONAR_TOKEN` und Org-Variable `SONAR_HOST_URL`; dieses Repo ist öffentlich und hält
deshalb keine internen Adressen, auch nicht in Beispielen.

Die Aktion entscheidet selbst, ob gescannt wird: Läufe von `renovate[bot]` und
`dependabot[bot]` sowie `skip: "true"` überspringen alles inklusive Cache-Schritt.
Pull Requests werden mit `sonar.pullrequest.*` analysiert, alle anderen Refs mit
`sonar.branch.name` — die `if:`-Bedingung und diese Parameter gehören nicht mehr ins
Verbraucherrepos.

### Defaults

| Input | Default |
| --- | --- |
| `sonar-host-url` | keine, Pflichteingabe; typisch aus einer Org-Variable |
| `socket-timeout-seconds` | `180` (Scanner-eigener Default ist 60) |
| `quality-gate` | `auto` |
| `blocking-refs` | `main` |
| `reference-branch` | `main` (`-Dsonar.newCode.referenceBranch`) |
| `branch-name` | `""` (nutzt `github.ref_name`) |
| `scanner` | `cli` (Alternativwert `maven`) |
| `project-dir` | `.` (Arbeitsverzeichnis im `maven`-Modus) |
| `skip-actors` | `renovate[bot],dependabot[bot]` |
| `cache` | `true` (`~/.sonar/cache`, Schlüssel `⟨OS⟩-sonar-⟨Serverfassung⟩`) |

`sonar.scanner.socketTimeout` ist der Socket-Timeout des Scanners gegen SonarWeb, in Sekunden. Bei
dem Default von 60 s brechen Bootstrap-Requests (`api/v2/analysis/version`, `api/rules/search`)
schon bei kurzen Transport-Störungen ab und der Run wird rot, obwohl der Server die Antwort noch
schreibt. Das ältere `sonar.ws.timeout` ist nur der Fallback dahinter — beide liest dieselbe Stelle
in `HttpConfig` der `sonar-scanner-java-library`, gesetzt wird deshalb ausschließlich der neue Name.

Der Scanner-Cache liegt unter `~/.sonar/cache` und enthält die Plugin-Jars des Servers. Sein
Schlüssel trägt deshalb die Serverfassung aus `GET /api/server/version`: nach einem SonarQube-Upgrade
zöge ein Schlüssel ohne Fassung die Jars der alten Fassung wieder her, und der Scan scheitert an
Dateien, auf die der Run keinen Einfluss hat. Antwortet der Server nicht, steht `unknown` im Schlüssel —
dann fehlt der Cache-Treffer, aber der Lauf läuft wie zuvor.

### Quality-Gate-Policy

Das Gate blockiert nur, wo eine belastbare New-Code-Baseline existiert: bei Pull Requests
(`sonar.pullrequest.*`, Baseline ist die Merge-Base) und bei Pushes auf `blocking-refs`
(`main`, Baseline ist der Referenz-Branch selbst). Alle anderen Branch-Analysen laufen mit
`sonar.qualitygate.wait=false`, werden also weiterhin analysiert und berichtet, machen den
Run aber nicht rot.

Grund: Vorschau-Branches, die `main` per Merge übernehmen, bekommen von SonarQube Zeilen als
"neuer Code" zugerechnet, die auf `main` längst alt sind. Beobachtet an drei unabhängigen
Lockfile-Bumps in portfolio-companion, die alle dieselbe Zahl melden:

```text
Bedingung:      new_coverage = 69.0 ( LT 80 )   -> Gate FAILED
gemessen:      new_lines_to_cover = 0, new_uncovered_lines = 0
```

Bei null zu testenden neuen Zeilen kann die Bedingung nicht erfüllt werden; dieselbe Analyse als
PR-Analyse meldet `PASSED`. Ein Blockieren auf solchen Branches erzeugt False-Positives, die
Renovate-PRs unbegrenzt liegen lassen. Mit `quality-gate: block` erzwingt die Wartung das
alte Verhalten zurück, mit `off` schaltet es ganz ab.

Mit funktionierender New-Code-Definition (siehe unten) ist die Baseline eines Vorschau-Branches
belastbar; `quality-gate: block` ist dann auch für Branches vertretbar. Nicht blockieren bleibt die
Default, weil ein Vorschau-Branch kein Merge-Ziel ist und sein Gate keine Entscheidung trifft.

### New-Code-Definition bei Branch-Analysen

Branch-Analysen erhalten `-Dsonar.newCode.referenceBranch=<reference-branch>` (Default `main`), auf
dem Referenz-Branch selbst entfällt der Parameter. Pull Requests brauchen ihn nicht, deren Referenz
ist `sonar.pullrequest.base`.

Ohne Referenz fällt SonarQube auf die zuletzt gemeldete Projektversion der Instanz zurück
(`PREVIOUS_VERSION`). Damit wird alter Code aus `main` zum neuen Code des Vorschau-Branches —
dieselbe Ursache wie die falsch bewerteten Gate-Bedingungen oben, und der Grund, warum mehrere
Vorschau-Branches identische Kennzahlen melden. Mit `reference-branch: ""` lässt sich der
Parameter abschalten, wenn die New-Code-Definition bewusst über `projectVersion` laufen soll.

Der Property-Name ist ein häufiger Fehler und wird von SonarQube kommentarlos ignoriert. Gemessen
an SonarQube Community Build 26.10.0.133078 mit je einer Wegwerf-Analyse von `portfolio-companion`
(Branch danach gelöscht):

| Argument | `api/new_code_periods/show` danach | Gate-Bedingungen |
| --- | --- | --- |
| `-Dsonar.referenceBranch=main` | `PREVIOUS_VERSION`, `inherited: true` | — |
| `-Dsonar.newCode.referenceBranch=main` | `REFERENCE_BRANCH`, `value: "main"` | nur `new_violations`, Gate `OK` |

`sonar.referenceBranch` ist also wirkungslos; die New-Code-Definition bleibt geerbt. Wer die
Definition nicht pro Analyse setzen, sondern dauerhaft am Branch verankern will, setzt sie einmal
über das REST-Endpunkt `POST /api/new_code_periods/set?project=<key>&branch=<branch>&type=REFERENCE_BRANCH&value=main`.
Das braucht einen Admin-Token; das Analyse-Token des Scanners reicht dafür nicht.

### Maven-Projekte: `scanner: maven`

Java-Projekte, deren Analyse den Classpath des Builds braucht, laufen nicht über die
Standalone-CLI. Die sieht den von Maven aufgebauten Classpath nicht, ihre Java-Regeln schalten
still ab und das Gate bleibt grün — ein Scan ohne Wirkung. Für sie ruft die Aktion den Scanner als
Plugin des Projekts auf:

```yaml
- name: SonarQube-Scan
  uses: taluma-gmbh/ci-tooling/.github/actions/sonar-scan@v1
  with:
    sonar-token: ${{ secrets.SONAR_TOKEN }}
    sonar-host-url: ${{ vars.SONAR_HOST_URL }}
    scanner: maven
    project-dir: .
    args: -Dsonar.projectKey=erechnung-service
```

Der Schritt führt `mvn -B sonar:sonar` im `project-dir` aus, mit denselben Argumenten wie im
`cli`-Modus; Token und Host kommen aus der Umgebung des Schritts. Zwei Bedingungen liegen im
Verbraucherrepos:

- Die Plugin-Version steht im pom unter `<build><plugins>`, nicht auf der Kommandozeile — nur so
  sieht Renovates Maven-Manager sie und hält den Scanner aktuell:

  ```xml
  <plugin>
    <groupId>org.sonarsource.scanner.maven</groupId>
    <artifactId>sonar-maven-plugin</artifactId>
    <version>5.0.0.4389</version>
  </plugin>
  ```

- Vor dem Scan muss `mvn package` (oder vergleichbar) gelaufen sein: `sonar:sonar` analysiert die
  Klassen im `target`-Verzeichnis und deckt sonst nichts ab.

### Bekannte Störung: Datums-Kollision bei schneller Abfolge

Die Compute Engine arbeitet Berichte pro Projekt sequentiell und verwirft einen Bericht, dessen
Analyse-Datum älter ist als das des zuletzt gespeicherten:

```text
ERROR: Validation of project failed:
  o Date of analysis cannot be older than the date of the last known analysis on this project.
    Value: "2026-11-22T10:54:49+0000". Latest analysis: "2026-11-22T10:54:53+0000".
```

Passiert, wenn mehrere Läufe desselben Projekts kurz hintereinander submiteten — Folge-Merges auf
`main`, Branch-Scan und PR-Scan desselben Commits, manuelle Läufe neben automatischen. Die
Plugin-Phase des Scanners schwankt zwischen Sekunden und Minuten, welche Analyse zuerst ankommt ist
nicht determiniert.

Die Action tut dagegen bewusst nichts: kein Vorab-Polling der CE-Queue, kein Doppelarbeitsschutz,
kein Retry. Alle drei haben HTTP gegen `api/ce/*` bedeutet (mit Token-Scope-Fragen und Warnungen
statt Wirkung) und haben damit mehr Oberfläche als Nutzen gebracht. Wirksam ist die Ursache
weniger Scans: derselbe Commit braucht keine Branch- *und* PR-Analyse, und ein Workflow, der
push und pull_request auf demselben Branch auslöst, erzeugt genau dieses Duell. Läuft ein Scan mit
dieser Meldung rot, ist der Re-Run des Jobs der richtige Umgang damit.

### Betriebswissen zum Server

Der Server hinter der Org-Variable `SONAR_HOST_URL` läuft als **Community Build 26.10.0.133078** mit
Community-Branch-Plugin (Scanner-Log: `com.github.mc1arke.sonarqube.plugin…`). Zwei Folgen, die
beide Pipelines treffen:

- Branch- und PR-Analysen existieren überhaupt erst über das Plugin; sein Aufräumen ist
  unvollständig. Gelöschte Git-Branches und geschlossene PRs hinterlassen Analyse-Einträge für
  immer. Das ist kein Grund, Branch-Scans abzuschalten — aber ein Grund, die Einträge regelmäßig
  über `api/project_branches/delete` und `api/project_pull_requests/delete` zu leeren (Admin-Token).
- Branch-Namen werden vom Plugin bereinigt und gekürzt: aus `renovate/postcss-selector-parser-7.x`
  wird `renovate-postcss-selector-parser`. API-Vergleiche zwischen Git und SonarQube müssen gegen
  diese Form prüfen, nicht gegen den Git-Namen.

## Secrets

Composite-Actions laufen im Job des **aufrufenden** Repositories und erben keine Secrets aus
diesem Repositorium. `SONAR_TOKEN` muss also dort liegen, wo der Job läuft:

- ein Repo-Secret `SONAR_TOKEN` pro Verbraucherrepos, oder
- ein **Org-Secret** `SONAR_TOKEN` (Org → Settings → Secrets and variables → Actions →
  Repository secrets), dann einmal gesetzt und in allen Repos des Orgs ohne weitere Pflege
  als `secrets.SONAR_TOKEN` sichtbar.

Empfohlen ist das Org-Secret. Dieses Repo selbst braucht kein `SONAR_TOKEN`: seine CI scannt
nicht gegen den Server, sie lintet nur die Action und testet die Argument-Berechnung.

## Versionierung und Konsum

- `main` ist die einzige Release-Branch. `semantic-release` erzeugt aus Conventional Commits
  Versions-Tags (`v1.2.3`) und einen GitHub-Release, danach zieht die `Release`-Pipeline den
  Major-Tag (`v1`) auf den neuen Commit.
- Verbraucherrepos verankern sich auf den Major-Tag: `@v1`. Brechende Änderungen erscheinen
  als `v2` und werden nicht automatisch angenommen.
- Renovate öffnet in den Verbraucherrepos Update-PRs für die `uses:`-Zeile, sobald hier ein
  neuer Tag entsteht (`github-actions`-Manager aus `config:recommended`).

## Weitere Actions anlegen

Eine neue Aktion ist ein neuer Ordner neben den bestehenden, mit eigenem `action.yml`:

```text
.github/actions/sonar-scan/{action.yml,sonar-args.sh}
.github/actions/setup-node-pnpm/action.yml
```

Verbraucher adressieren den Pfad, nicht das Repo allein:

```yaml
uses: taluma-gmbh/ci-tooling/.github/actions/setup-node-pnpm@v1
```

Wichtig dabei:

- Der `ref` (`@v1`) gilt für das **ganze Repo**, nicht pro Ordner. `v1` ist ein Commit-Zeiger,
  alle Ordner werden zusammen versioniert. Eine neue Aktion erscheint automatisch mit dem
  nächsten Release, ein eigener Tag pro Ordner ist nicht möglich.
- Da der `ref` geteilt ist, hebt eine brechende Änderung an einer Aktion den Major für alle.
  Inputs deshalb nur ergänzend ändern (neue Inputs mit Default), umbenennen oder entfernen
  ist ein `BREAKING CHANGE`.
- Der Pfad ist Teil der öffentlichen Schnittstelle: Ordner umbenennen bricht alle Verbraucher.
- `${{ github.action_path }}` zeigt auf den jeweiligen Ordner, dort liegen ausführbare
  Begleitdateien wie `sonar-args.sh`. Pro Ordner eine Testdatei unter `test/` anlegen und in
  `.github/workflows/ci.yml` aufrufen.
- Ein `action.yml` direkt in der Repo-Wurzel wäre die "eine Aktion pro Repo"-Form und wäre
  dann mit `uses: taluma-gmbh/ci-tooling@v1` ansprechbar; beides nebeneinander ist möglich.

## Dieses Repo hält sich selbst aktuell

- `renovate.json` erweitert `github>taluma-gmbh/renovate-config`, damit gelten dieselben
  Regeln wie überall (Automerge für minor/patch nach Reifezeit, Major von Hand).
- Renovate aktualisiert hier die `uses:`-Zeilen der Fremd-Actions
  (`SonarSource/sonarqube-scan-action`, `actions/*`) und `semantic-release` aus `package.json`.
- Für die private geteilte Config wird ein Repository-Secret `RENOVATE_TOKEN` mit Leserechten
  auf `taluma-gmbh/renovate-config` benötigt — genau wie in den anderen Repos.

## Entwicklung

```bash
bash test/sonar-args.test.sh
```

Die CI führt zusätzlich `actionlint` und `shellcheck` in Docker aus. Logik der Action bleibt in
`sonar-args.sh`, weil sie dort testbar ist; `action.yml` enthält nur noch Assembly.

## Roadmap

Kandidaten für weitere Aktionen, gleiche Struktur:

- `setup-node-pnpm`: Node und pnpm nach `packageManager`-Field installieren
- `docker-build-push`: Login, Buildx, Build, Push mit einheitlichen Tags
- `deploy-helm`: Helm-Lint, Template-Test, `helm upgrade --install`
