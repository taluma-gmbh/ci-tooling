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
          project-version: ${{ steps.version.outputs.version }}
          args: -Dsonar.sources=src
```

Die Aktion entscheidet selbst, ob gescannt wird: Läufe von `renovate[bot]` und
`dependabot[bot]` sowie `skip: "true"` überspringen alles inklusive Cache-Schritt.
Pull Requests werden mit `sonar.pullrequest.*` analysiert, alle anderen Refs mit
`sonar.branch.name` — die `if:`-Bedingung und diese Parameter gehören nicht mehr ins
Verbraucherrepos.

### Defaults

| Input | Default |
| --- | --- |
| `sonar-host-url` | `https://sonar.taluma-appserver.de` |
| `ws-timeout-seconds` | `180` (Scanner-eigener Default ist 60) |
| `quality-gate` | `auto` |
| `blocking-refs` | `main` |
| `branch-name` | `""` (nutzt `github.ref_name`) |
| `skip-actors` | `renovate[bot],dependabot[bot]` |
| `cache` | `true` (`~/.sonar/cache`) |

`sonar.ws.timeout` ist der Socket-Timeout des Scanners gegen SonarWeb. Bei 60 s brechen
Bootstrap-Requests (`api/v2/analysis/version`, `api/rules/search`) schon bei kurzen
Transport-Störungen ab und der Run wird rot, obwohl der Server die Antwort noch schreibt.

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

Bei null zu testenden neuen Zeilen kann die Bedingung nicht erfüllen; dieselbe Analyse als
PR-Analyse meldet `PASSED`. Ein Blockieren auf solchen Branches erzeugt False-Positives, die
Renovate-PRs unbegrenzt liegen lassen. Mit `quality-gate: block` erzwingt die Wartung das
alte Verhalten zurück, mit `off` schaltet es ganz ab.

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
