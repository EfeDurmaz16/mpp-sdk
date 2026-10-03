#!/usr/bin/env bash
# Source this file inside a Nix shell. Dependency downloads remain runtime work.

nix_setup_language() {
  local language="${1:?language is required}"
  local purpose="${2:-unit}"
  local root
  root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
  case "$purpose" in
    unit|interop) ;;
    *) printf 'Unknown language setup purpose: %s\n' "$purpose" >&2; return 2 ;;
  esac
  printf 'Preparing %s dependencies for %s checks\n' "$language" "$purpose"

  case "$language" in
    python)
      # Keep pip away from the immutable Nix Python installation. uv adapters
      # inherit the same pinned interpreter and cannot download another one.
      export UV_PYTHON
      UV_PYTHON="$(command -v python3.11)"
      export UV_PYTHON_DOWNLOADS=never
      export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$root/.nix-work/cache/pip}"
      export UV_CACHE_DIR="${UV_CACHE_DIR:-$root/.nix-work/cache/uv}"
      mkdir -p "$PIP_CACHE_DIR" "$UV_CACHE_DIR"
      export UV_PROJECT_ENVIRONMENT="$root/.nix-work/python-$purpose"
      export VIRTUAL_ENV="$UV_PROJECT_ENVIRONMENT"
      if [[ "$purpose" == unit ]]; then
        "$UV_PYTHON" -m venv "$VIRTUAL_ENV"
        export PATH="$VIRTUAL_ENV/bin:$PATH"
        python --version
        python -m pip install --upgrade pip
        (cd "$root/python" && python -m pip install -e '.[dev,fastapi,flask,django]')
      else
        uv --version
        (cd "$root/python" && uv sync --locked --extra dev)
        export PATH="$VIRTUAL_ENV/bin:$PATH"
        python --version
      fi
      ;;
    ruby)
      export BUNDLE_PATH="${BUNDLE_PATH:-$root/.nix-work/bundle}"
      ruby --version
      bundle --version
      (cd "$root/ruby" && bundle install)
      ;;
    lua)
      # Nixpkgs does not contain the full rock set used by the existing CI.
      # Explicit include/library paths keep C rocks on the Nix toolchain.
      : "${LUA_INCDIR:?Nix shell must provide LUA_INCDIR}"
      : "${LIBSODIUM_INCDIR:?Nix shell must provide LIBSODIUM_INCDIR}"
      : "${LIBSODIUM_LIBDIR:?Nix shell must provide LIBSODIUM_LIBDIR}"
      : "${OPENSSL_INCDIR:?Nix shell must provide OPENSSL_INCDIR}"
      : "${OPENSSL_LIBDIR:?Nix shell must provide OPENSSL_LIBDIR}"
      local rock
      local rocks=(luasocket luasodium luasec lua-resty-openssl lua-cjson)
      if [[ "$purpose" == unit ]]; then
        rocks+=(luacheck luacov cluacov)
      fi
      luajit -v
      luarocks --version
      mkdir -p "$root/lua/lua_modules"
      for rock in "${rocks[@]}"; do
        # Only an exact cache contract permits skipping a rock installation.
        # The contract includes the Nix compiler/native libraries, rockspecs,
        # setup script, purpose and a weekly refresh for unpinned rocks.
        if [[ "${NIX_RUNTIME_CACHE_LUA_HIT:-false}" == true ]] &&
          luarocks --lua-version=5.1 --tree "$root/lua/lua_modules" show "$rock" >/dev/null 2>&1; then
          printf 'Reusing compatible Lua rock: %s\n' "$rock"
          continue
        fi
        luarocks --lua-version=5.1 --tree "$root/lua/lua_modules" install "$rock" \
          "LUA_INCDIR=$LUA_INCDIR" \
          "SODIUM_INCDIR=$LIBSODIUM_INCDIR" \
          "SODIUM_LIBDIR=$LIBSODIUM_LIBDIR" \
          "OPENSSL_INCDIR=$OPENSSL_INCDIR" \
          "OPENSSL_LIBDIR=$OPENSSL_LIBDIR"
      done
      # The unchanged Lua harness adapter also resolves this local rocks tree.
      eval "$(luarocks --lua-version=5.1 --tree "$root/lua/lua_modules" path)"
      if [[ "$(uname -s)" == Darwin ]]; then
        export DYLD_LIBRARY_PATH="$LIBSODIUM_LIBDIR:$OPENSSL_LIBDIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
      else
        export LD_LIBRARY_PATH="$LIBSODIUM_LIBDIR:$OPENSSL_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      fi
      ;;
    php)
      export COMPOSER_CACHE_DIR="${COMPOSER_CACHE_DIR:-$root/.nix-work/cache/composer}"
      mkdir -p "$COMPOSER_CACHE_DIR"
      php --version
      composer --version
      if [[ "$purpose" == unit ]]; then
        php -r 'if (!extension_loaded("pcov")) { fwrite(STDERR, "The Nix PHP shell must enable pcov.\n"); exit(1); }'
      fi
      (cd "$root/php" && composer install --no-interaction --no-progress)
      ;;
    kotlin)
      export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$root/.nix-work/gradle}"
      # Prevent daemons from surviving the lane and avoid caching test outputs.
      export GRADLE_OPTS="${GRADLE_OPTS:-} -Dorg.gradle.daemon=false -Dorg.gradle.caching=false"
      java -version
      gradle --version
      ;;
    swift)
      # CryptoKit currently makes the existing Swift lane a Darwin lane.
      if [[ "$(uname -s)" != Darwin ]]; then
        printf 'The current Swift SDK checks require Darwin.\n' >&2
        return 1
      fi
      swift --version
      ;;
    *) printf 'Unknown language: %s\n' "$language" >&2; return 2 ;;
  esac
}
