#!/usr/bin/env bash
# The gates below mirror the corresponding existing language workflows.
set -euo pipefail

language="${1:?Usage: bash nix/scripts/languages.sh <python|ruby|lua|php|kotlin|swift>}"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=language-setup.sh
source "$root/nix/scripts/language-setup.sh"

copy_report() {
  local source_path="$1"
  if [[ -e "$source_path" ]]; then
    cp -R "$source_path" "$root/.nix-results/$language/"
  fi
}

collect_reports() {
  local status=$?
  trap - EXIT
  mkdir -p "$root/.nix-results/$language"
  case "$language" in
    python) copy_report "$root/python/coverage.json" ;;
    ruby)
      copy_report "$root/ruby/coverage/.resultset.json"
      copy_report "$root/ruby/target/surfpool-reports"
      ;;
    lua)
      copy_report "$root/luacov.report.out"
      copy_report "$root/lua/target/surfpool-reports"
      ;;
    php) copy_report "$root/php/build/coverage/clover.xml" ;;
    kotlin) copy_report "$root/kotlin/build/reports/jacoco/test" ;;
    swift) copy_report "$root/.build/debug/codecov" ;;
  esac
  exit "$status"
}
trap collect_reports EXIT

nix_setup_language "$language" unit
set -x
case "$language" in
  python)
    cd "$root/python"
    ruff check src tests
    pyright --pythonpath "$(python -c 'import sys; print(sys.executable)')"
    pytest --cov=solana_pay_kit --cov-report=term-missing \
      --cov-report=json:coverage.json --cov-fail-under=90 \
      --ignore=tests/test_server_html.py
    ;;
  ruby)
    cd "$root/ruby"
    bundle exec ruby -e "Gem::Specification.load('solana-pay-kit.gemspec').validate"
    bundle exec standardrb
    bundle exec bundle-audit check --update
    SURFPOOL_REPORT=1 COVERAGE=1 bundle exec ruby -Itest test/run.rb
    ;;
  lua)
    cd "$root/lua"
    luarocks --lua-version=5.1 lint pay-kit-dev-1.rockspec
    luarocks --lua-version=5.1 lint kong-plugin-pay-kit-dev-1.rockspec
    luarocks --lua-version=5.1 lint apisix-plugin-pay-kit-dev-1.rockspec
    luacheck pay_kit/ plugins/ tests/
    rm -f ../luacov.stats.out ../luacov.report.out
    SURFPOOL_REPORT=1 luajit -lluacov tests/run.lua
    luacov
    ./scripts/check_coverage.sh ../luacov.report.out 90
    luajit tests/run.lua
    ;;
  php)
    cd "$root/php"
    composer validate --strict
    composer audit --no-dev
    composer run lint
    mkdir -p build/coverage
    composer run test:coverage
    ;;
  kotlin)
    cd "$root/kotlin"
    gradle check
    ;;
  swift)
    swift test --enable-code-coverage
    ;;
esac
