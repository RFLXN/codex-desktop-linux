#!/usr/bin/env bash
set -Eeuo pipefail

WORK_DIR="${TMPDIR:-/tmp}/codex-build"
SEVEN_ZIP_CMD="$(command -v 7zz || command -v 7z)"

info() {
    echo "[nix-build] $*" >&2
}

error() {
    echo "[nix-build][ERROR] $*" >&2
    exit 1
}

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'error "Failed at line $LINENO (exit code $?)"' ERR

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

require_env() {
    local name="$1"
    [ -n "${!name:-}" ] || error "Missing required environment variable: $name"
}

fix_shebangs() {
    local bin_dir="$1"

    [ -d "$bin_dir" ] || return 0

    while IFS= read -r -d '' file; do
        local first_line interpreter_path
        first_line="$(head -n 1 "$file" || true)"
        case "$first_line" in
            '#!/usr/bin/env '*)
                interpreter_path="$(command -v "${first_line##* }" || true)"
                if [ -n "$interpreter_path" ]; then
                    sed -i "1s|^#!.*$|#!$interpreter_path|" "$file"
                fi
                ;;
        esac
    done < <(find "$bin_dir" -maxdepth 1 -type f -print0)
}

extract_dmg() {
    local extract_dir="$WORK_DIR/dmg-extract"
    local seven_log="$WORK_DIR/7z.log"
    local seven_zip_status=0

    mkdir -p "$extract_dir"
    if "$SEVEN_ZIP_CMD" x -y -snl "$DMG_PATH" -o"$extract_dir" >"$seven_log" 2>&1; then
        :
    else
        seven_zip_status=$?
    fi

    local app_dir
    app_dir="$(find "$extract_dir" -maxdepth 3 -name "*.app" -type d | head -n 1)"

    if [ "$seven_zip_status" -ne 0 ]; then
        if [ -n "$app_dir" ]; then
            info "7z exited with code $seven_zip_status but app bundle was found; continuing"
        else
            cat "$seven_log" >&2
            error "Failed to extract DMG"
        fi
    fi

    [ -n "$app_dir" ] || error "Could not find .app bundle in DMG"
    printf '%s\n' "$app_dir"
}

build_native_modules() {
    local extracted_root="$1"
    local build_dir="$WORK_DIR/native-build"
    local bs3_ver
    local npty_ver

    bs3_ver="$(node -p "require('$extracted_root/node_modules/better-sqlite3/package.json').version")"
    npty_ver="$(node -p "require('$extracted_root/node_modules/node-pty/package.json').version")"

    [ -n "$bs3_ver" ] || error "Could not detect better-sqlite3 version"
    [ -n "$npty_ver" ] || error "Could not detect node-pty version"

    info "Rebuilding Linux native modules: better-sqlite3@$bs3_ver node-pty@$npty_ver"

    mkdir -p "$build_dir"
    cd "$build_dir"

    printf '%s\n' '{"private":true}' > package.json

    npm install --no-package-lock --ignore-scripts "electron@$ELECTRON_VERSION"
    npm install --no-package-lock --ignore-scripts "@electron/rebuild" \
        "better-sqlite3@$bs3_ver" "node-pty@$npty_ver"
    node "$(readlink -f "$build_dir/node_modules/.bin/electron-rebuild")" \
        -v "$ELECTRON_VERSION" --force

    rm -rf "$extracted_root/node_modules/better-sqlite3" "$extracted_root/node_modules/node-pty"
    cp -r "$build_dir/node_modules/better-sqlite3" "$extracted_root/node_modules/"
    cp -r "$build_dir/node_modules/node-pty" "$extracted_root/node_modules/"
}

sanitize_app_tree() {
    local extracted_root="$1"
    local node_pty_config="$extracted_root/node_modules/node-pty/build/config.gypi"

    if [ -f "$node_pty_config" ]; then
        sed -i 's|"/nix/store/[^"]*/bin/python3"|"python3"|g' "$node_pty_config"
    fi
}

setup_asar_tooling() {
    local tools_dir="$WORK_DIR/asar-tools"

    if [ -x "$tools_dir/node_modules/.bin/asar" ]; then
        printf '%s\n' "$tools_dir"
        return 0
    fi

    mkdir -p "$tools_dir"
    cd "$tools_dir"
    printf '%s\n' '{"private":true}' > package.json
    npm install --no-package-lock --ignore-scripts "asar" >&2
    printf '%s\n' "$tools_dir"
}

patch_asar() {
    local app_dir="$1"
    local resources_dir="$app_dir/Contents/Resources"
    local tools_dir

    local asar_cli

    [ -f "$resources_dir/app.asar" ] || error "app.asar not found in $resources_dir"
    tools_dir="$(setup_asar_tooling)"
    asar_cli="$(readlink -f "$tools_dir/node_modules/.bin/asar")"

    info "Extracting app.asar"
    cd "$WORK_DIR"
    node "$asar_cli" extract "$resources_dir/app.asar" app-extracted

    if [ -d "$resources_dir/app.asar.unpacked" ]; then
        mkdir -p "$WORK_DIR/app.asar.unpacked"
        cp -r "$resources_dir/app.asar.unpacked/." "$WORK_DIR/app.asar.unpacked/"
        cp -r "$resources_dir/app.asar.unpacked/." app-extracted/
    fi

    rm -rf "$WORK_DIR/app-extracted/node_modules/sparkle-darwin"
    find "$WORK_DIR/app-extracted" -name "sparkle.node" -delete

    build_native_modules "$WORK_DIR/app-extracted"
    sanitize_app_tree "$WORK_DIR/app-extracted"
    cd "$WORK_DIR"

    info "Applying Linux UI patch"
    node "$PATCH_SCRIPT" "$WORK_DIR/app-extracted"

    info "Repacking app.asar"
    rm -f "$WORK_DIR/app.asar"
    rm -rf "$WORK_DIR/app.asar.unpacked"
    node "$asar_cli" pack app-extracted app.asar --unpack "{*.node,*.so,*.dylib}"
}

install_electron_runtime() {
    info "Installing Electron v$ELECTRON_VERSION runtime"
    mkdir -p "$INSTALL_DIR"
    unzip -qo "$ELECTRON_ZIP" -d "$INSTALL_DIR"
}

extract_webview() {
    local webview_root="$INSTALL_DIR/content/webview"
    local webview_index="$webview_root/index.html"

    mkdir -p "$webview_root"
    if [ -d "$WORK_DIR/app-extracted/webview" ]; then
        cp -r "$WORK_DIR/app-extracted/webview/." "$webview_root/"
        if [ -f "$webview_index" ]; then
            sed -i 's/--startup-background: transparent/--startup-background: #1e1e1e/' "$webview_index"
        fi
    else
        error "Webview directory not found in extracted app.asar"
    fi
}

install_app_payload() {
    mkdir -p "$INSTALL_DIR/resources"
    cp "$WORK_DIR/app.asar" "$INSTALL_DIR/resources/app.asar"

    if [ -d "$WORK_DIR/app.asar.unpacked" ]; then
        rm -rf "$INSTALL_DIR/resources/app.asar.unpacked"
        cp -r "$WORK_DIR/app.asar.unpacked" "$INSTALL_DIR/resources/"
    fi
}

sanitize_install_tree() {
    while IFS= read -r -d '' file; do
        if patchelf --print-rpath "$file" >/dev/null 2>&1; then
            patchelf --remove-rpath "$file"
            python3 - "$file" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
data = re.sub(rb"/nix/store/[^\x00]+", lambda match: b"x" * len(match.group(0)), data)
path.write_bytes(data)
PY
        fi
    done < <(find "$INSTALL_DIR" -type f -print0)
}

create_start_script() {
    mkdir -p "$INSTALL_DIR/.codex-linux"
    cp "$ICON_SOURCE" "$INSTALL_DIR/.codex-linux/codex-desktop.png"

    cat > "$INSTALL_DIR/start.sh" <<SCRIPT
#!$NIX_BASH
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
WEBVIEW_DIR="\$SCRIPT_DIR/content/webview"
LOG_DIR="\${XDG_CACHE_HOME:-\$HOME/.cache}/codex-desktop"
LOG_FILE="\$LOG_DIR/launcher.log"
APP_STATE_DIR="\${XDG_STATE_HOME:-\$HOME/.local/state}/codex-desktop"
APP_PID_FILE="\$APP_STATE_DIR/app.pid"
PACKAGED_RUNTIME_HELPER="\$SCRIPT_DIR/.codex-linux/codex-packaged-runtime.sh"
APP_NOTIFICATION_ICON_NAME="codex-desktop"
APP_NOTIFICATION_ICON_BUNDLE="\$SCRIPT_DIR/.codex-linux/\$APP_NOTIFICATION_ICON_NAME.png"
APP_NOTIFICATION_ICON_SYSTEM="/usr/share/icons/hicolor/256x256/apps/\$APP_NOTIFICATION_ICON_NAME.png"
APP_NOTIFICATION_ICON_REPO="\$SCRIPT_DIR/../assets/codex.png"

mkdir -p "\$LOG_DIR" "\$APP_STATE_DIR"

if [[ "\${1:-}" == "--help" || "\${1:-}" == "-h" ]]; then
    cat <<'HELP'
Usage: codex-desktop [OPTIONS] [-- ELECTRON_FLAGS...]

Launches the Codex Desktop app.

Options:
  -h, --help                  Show this help message and exit
  --disable-gpu               Completely disable GPU acceleration
  --disable-gpu-compositing   Disable GPU compositing (fixes flickering)
  --ozone-platform=x11        Force X11 instead of Wayland

Extra flags are passed directly to Electron.

Logs: ~/.cache/codex-desktop/launcher.log
HELP
    exit 0
fi

exec >>"\$LOG_FILE" 2>&1

echo "[\$(date -Is)] Starting Codex Desktop launcher"

load_packaged_runtime_helper() {
    if [ -f "\$PACKAGED_RUNTIME_HELPER" ]; then
        # shellcheck disable=SC1090
        . "\$PACKAGED_RUNTIME_HELPER"
    fi
}

run_packaged_runtime_prelaunch() {
    if declare -F codex_packaged_runtime_prelaunch >/dev/null 2>&1; then
        codex_packaged_runtime_prelaunch
    fi
}

export_packaged_runtime_env() {
    if declare -F codex_packaged_runtime_export_env >/dev/null 2>&1; then
        codex_packaged_runtime_export_env
    fi
}

run_cli_preflight() {
    if ! command -v codex-update-manager >/dev/null 2>&1; then
        return 0
    fi

    local refreshed_path=""
    if ! refreshed_path="\$(codex-update-manager cli-preflight --cli-path "\${CODEX_CLI_PATH:-}" --print-path)"; then
        notify_error "Codex CLI prelaunch update check failed. Continuing with the current CLI."
        return 0
    fi

    if [ -n "\$refreshed_path" ]; then
        CODEX_CLI_PATH="\$refreshed_path"
        export CODEX_CLI_PATH
    fi
}

resolve_notification_icon() {
    local candidate
    for candidate in \
        "\$APP_NOTIFICATION_ICON_BUNDLE" \
        "\$APP_NOTIFICATION_ICON_SYSTEM" \
        "\$APP_NOTIFICATION_ICON_REPO"
    do
        if [ -f "\$candidate" ]; then
            echo "\$candidate"
            return 0
        fi
    done

    echo "\$APP_NOTIFICATION_ICON_NAME"
}

find_codex_cli() {
    if command -v codex >/dev/null 2>&1; then
        command -v codex
        return 0
    fi

    if [ -s "\${NVM_DIR:-\$HOME/.nvm}/nvm.sh" ]; then
        export NVM_DIR="\${NVM_DIR:-\$HOME/.nvm}"
        # shellcheck disable=SC1090
        . "\$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
        if command -v codex >/dev/null 2>&1; then
            command -v codex
            return 0
        fi
    fi

    local candidate
    for candidate in \
        "\$HOME/.nvm/versions/node/current/bin/codex" \
        "\$HOME/.nvm/versions/node"/*/bin/codex \
        "\$HOME/.local/share/pnpm/codex" \
        "\$HOME/.local/bin/codex" \
        "/usr/local/bin/codex" \
        "/usr/bin/codex"
    do
        if [ -x "\$candidate" ]; then
            echo "\$candidate"
            return 0
        fi
    done

    return 1
}

notify_error() {
    local message="\$1"
    local icon
    icon="\$(resolve_notification_icon)"
    echo "\$message"
    if command -v notify-send >/dev/null 2>&1; then
        notify-send \
            -a "Codex Desktop" \
            -i "\$icon" \
            -h "string:desktop-entry:codex-desktop" \
            "Codex Desktop" \
            "\$message"
    fi
}

wait_for_webview_server() {
    echo "Waiting for webview server on :5175"

    local attempt
    for attempt in \$(seq 1 50); do
        if python3 -c "import socket; s=socket.socket(); s.settimeout(0.5); s.connect(('127.0.0.1', 5175)); s.close()" 2>/dev/null; then
            echo "Webview server is ready"
            return 0
        fi
        sleep 0.1
    done

    return 1
}

verify_webview_origin() {
    local url="\$1"

    python3 - "\$url" <<'PY'
import sys
import urllib.request

url = sys.argv[1]
required_markers = ("<title>Codex</title>", "startup-loader")

with urllib.request.urlopen(url, timeout=2) as response:
    body = response.read(8192).decode("utf-8", "ignore")

missing = [marker for marker in required_markers if marker not in body]
if missing:
    raise SystemExit(
        f"Webview origin validation failed for {url}; missing markers: {', '.join(missing)}"
    )
PY
}

clear_stale_pid_file() {
    if [ ! -f "\$APP_PID_FILE" ]; then
        return 0
    fi

    local pid=""
    pid="\$(cat "\$APP_PID_FILE" 2>/dev/null || true)"
    if [ -z "\$pid" ] || ! kill -0 "\$pid" 2>/dev/null; then
        rm -f "\$APP_PID_FILE"
    fi
}

load_packaged_runtime_helper
clear_stale_pid_file
run_packaged_runtime_prelaunch
pkill -f "http.server 5175" 2>/dev/null || true
sleep 0.5

if [ -d "\$WEBVIEW_DIR" ] && [ "\$(ls -A "\$WEBVIEW_DIR" 2>/dev/null)" ]; then
    cd "\$WEBVIEW_DIR"
    nohup python3 -m http.server 5175 &
    HTTP_PID=\$!
    trap "kill \$HTTP_PID 2>/dev/null" EXIT

    echo "Started webview server pid=\$HTTP_PID dir=\$WEBVIEW_DIR"

    if ! wait_for_webview_server; then
        notify_error "Codex Desktop webview server did not become ready on port 5175."
        exit 1
    fi

    if ! kill -0 "\$HTTP_PID" 2>/dev/null; then
        notify_error "Codex Desktop webview server exited before Electron launch."
        exit 1
    fi

    if ! verify_webview_origin "http://127.0.0.1:5175/index.html"; then
        notify_error "Codex Desktop webview origin validation failed."
        exit 1
    fi

    echo "Webview origin verified."
fi

if [ -z "\${CODEX_CLI_PATH:-}" ]; then
    CODEX_CLI_PATH="\$(find_codex_cli || true)"
    export CODEX_CLI_PATH
fi
export CHROME_DESKTOP="\${CHROME_DESKTOP:-codex-desktop.desktop}"

if [ -z "\$CODEX_CLI_PATH" ]; then
    notify_error "Codex CLI not found. Install with: npm i -g @openai/codex"
    exit 1
fi

run_cli_preflight
export_packaged_runtime_env

echo "Using CODEX_CLI_PATH=\$CODEX_CLI_PATH"

cd "\$SCRIPT_DIR"
echo "\$\$" > "\$APP_PID_FILE"
exec "\$SCRIPT_DIR/electron" \
    --no-sandbox \
    --class=codex-desktop \
    --app-id=codex-desktop \
    --ozone-platform-hint=auto \
    --disable-gpu-sandbox \
    --disable-gpu-compositing \
    --enable-features=WaylandWindowDecorations \
    "\$@"
SCRIPT

    chmod 0755 "$INSTALL_DIR/start.sh"
}

main() {
    require_env DMG_PATH
    require_env ELECTRON_ZIP
    require_env ELECTRON_VERSION
    require_env PATCH_SCRIPT
    require_env ICON_SOURCE
    require_env INSTALL_DIR
    require_env NIX_BASH

    local app_dir
    app_dir="$(extract_dmg)"

    patch_asar "$app_dir"
    install_electron_runtime
    extract_webview
    install_app_payload
    sanitize_install_tree
    create_start_script
}

main "$@"
