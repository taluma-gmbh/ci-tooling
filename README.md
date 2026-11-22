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
| `quality-gate-wait` | `true` |
| `skip-actors` | `renovate[bot],dependabot[bot]` |
| `cache` | `true` (`~/.sonar/cache`) |

`sonar.ws.timeout` ist der Socket-Timeout des Scanners gegen SonarWeb. Bei 60 s brechen
Bootstrap-Requests (`api/v2/analysis/version`, `api/rules/search`) schon bei kurzen
Transport-Störungen ab und der Run wird rot, obwohl der Server die Antwort noch schreibt.

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
