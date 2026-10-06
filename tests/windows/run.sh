#!/usr/bin/env bash
# shellcheck disable=SC2016  # PowerShell-lausekkeet välitetään tarkoituksella sellaisinaan
# PSScriptAnalyzer ja Pester konttiin rakennetulla pwsh:lla (tests/windows/Containerfile). [VERKKO: rakennus]
#   tests/windows/run.sh [analyze|pester|all]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMG=localhost/acme-test-pwsh:1
podman image exists "$IMG" || podman build -q -t "$IMG" "$ROOT/tests/windows" >/dev/null
RUN=(podman run --rm --network none --security-opt label=disable -v "$ROOT:/src:ro" -w /src "$IMG" pwsh -NoProfile -NonInteractive -Command)

analyze() {
  echo "== PSScriptAnalyzer (PS 5.1 -yhteensopivuus)"
  "${RUN[@]}" '$r = Invoke-ScriptAnalyzer -Path windows -Recurse -Settings tests/windows/PSScriptAnalyzerSettings.psd1
    $r | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message | Out-String -Width 250 | Write-Output
    if ($r) { exit 1 } else { Write-Output "puhdas" }'
}
pester() {
  echo "== Pester"
  "${RUN[@]}" '$c = New-PesterConfiguration; $c.Run.Path = "tests/windows"; $c.Run.Exit = $true
    $c.Output.Verbosity = "Detailed"; Invoke-Pester -Configuration $c'
}
case "${1:-all}" in
  analyze) analyze ;;
  pester) pester ;;
  all) analyze; pester ;;
  *) echo "Käyttö: $0 [analyze|pester|all]" >&2; exit 2 ;;
esac
