{ lib
, stdenv
, stdenvNoCC
, bash
, nodejs
, python3
, p7zip
, curl
, unzip
, gnumake
, gcc
, patchelf
, coreutils
, diffutils
, findutils
, gnugrep
, gnused
, libnotify
, procps
, util-linux
, fetchurl
, glib
, gtk3
, pango
, cairo
, gdk-pixbuf
, atk
, at-spi2-atk
, at-spi2-core
, nss
, nspr
, dbus
, cups
, expat
, libdrm
, mesa
, libgbm
, alsa-lib
, libX11
, libXcomposite
, libXdamage
, libXext
, libXfixes
, libXrandr
, libxcb
, libxkbcommon
, libxcursor
, libxi
, libxtst
, libxscrnsaver
, libglvnd
, systemd
, wayland
, codexDmg ? fetchurl {
    url = "https://persistent.oaistatic.com/codex-app-prod/Codex.dmg";
    hash = "sha256-uSOeP7IozPh54EKyPyRwQ1xTwfL8lIStWS27ibg7ir8=";
  }
}:

let
  sourceRoot = lib.cleanSourceWith {
    src = ./.;
    filter = path: type:
      lib.cleanSourceFilter path type
      && (let
        pathStr = toString path;
      in
        !(lib.hasSuffix "/.codex" pathStr || lib.hasInfix "/.codex/" pathStr));
  };

  runtimeTools = [
    bash
    nodejs
    python3
    p7zip
    curl
    unzip
    gnumake
    gcc
    patchelf
    coreutils
    diffutils
    findutils
    gnugrep
    gnused
    libnotify
    procps
    util-linux
  ];

  electronLibPath = lib.makeLibraryPath [
    glib
    gtk3
    pango
    cairo
    gdk-pixbuf
    atk
    at-spi2-atk
    at-spi2-core
    nss
    nspr
    dbus
    cups
    expat
    libdrm
    mesa
    libgbm
    alsa-lib
    libX11
    libXcomposite
    libXdamage
    libXext
    libXfixes
    libXrandr
    libxcb
    libxkbcommon
    libxcursor
    libxi
    libxtst
    libxscrnsaver
    libglvnd
    systemd
    wayland
  ];

  packageStamp = builtins.hashString "sha256" ''
    source=${toString sourceRoot}
    dmg=${toString codexDmg}
    electronLibPath=${electronLibPath}
  '';

  version = "unstable-${builtins.substring 0 12 packageStamp}";

  runtimePath = lib.makeBinPath runtimeTools;
  desktopFile = "${sourceRoot}/packaging/linux/codex-desktop.desktop";
  iconFile = "${sourceRoot}/assets/codex.png";
in
stdenvNoCC.mkDerivation {
  pname = "codex-desktop";
  inherit version;

  dontUnpack = true;

  installPhase = ''
    mkdir -p \
      "$out/bin" \
      "$out/share/applications" \
      "$out/share/icons/hicolor/256x256/apps"

    cat > "$out/bin/codex-desktop" <<'SCRIPT'
#!${bash}/bin/bash
set -euo pipefail

export PATH='${runtimePath}':"$PATH"

RUNTIME_ROOT="''${CODEX_NIX_RUNTIME_ROOT:-''${XDG_DATA_HOME:-$HOME/.local/share}/codex-desktop-nix}"
APP_DIR="$RUNTIME_ROOT/codex-app"
STAMP_FILE="$RUNTIME_ROOT/build-stamp"
LOCK_FILE="$RUNTIME_ROOT/install.lock"
EXPECTED_STAMP='${packageStamp}'

mkdir -p "$RUNTIME_ROOT"
exec 9>"$LOCK_FILE"
flock 9

stamp_matches() {
    [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$EXPECTED_STAMP" ]
}

app_ready() {
    [ -x "$APP_DIR/start.sh" ] && [ -x "$APP_DIR/electron" ]
}

patch_nixos_runtime() {
    local install_dir="$1"
    local dynamic_linker
    dynamic_linker="$(cat '${stdenv.cc}/nix-support/dynamic-linker')"

    if [ -f "$install_dir/start.sh" ]; then
        sed -i "1s|^#!/bin/bash$|#!${bash}/bin/bash|" "$install_dir/start.sh"
    fi

    if [ -f "$install_dir/electron" ]; then
        echo "[NIX] Patching Electron runtime in $install_dir"
        patchelf --set-interpreter "$dynamic_linker" \
                 --set-rpath "$install_dir:${electronLibPath}" \
                 "$install_dir/electron"

        if [ -f "$install_dir/chrome_crashpad_handler" ]; then
            patchelf --set-interpreter "$dynamic_linker" \
                     "$install_dir/chrome_crashpad_handler" || true
        fi

        if [ -f "$install_dir/chrome-sandbox" ]; then
            patchelf --set-interpreter "$dynamic_linker" \
                     "$install_dir/chrome-sandbox" || true
        fi

        find "$install_dir" -maxdepth 1 -name "*.so*" -type f | while read -r so; do
            patchelf --set-rpath '${electronLibPath}' "$so" 2>/dev/null || true
        done
    fi
}

materialize_app() {
    local build_root
    build_root="$(mktemp -d "$RUNTIME_ROOT/build.XXXXXX")"

    cleanup_build_root() {
        rm -rf "$build_root"
    }
    trap cleanup_build_root RETURN

    local install_dir="$build_root/codex-app"

    echo "[NIX] Materializing Codex Desktop into $APP_DIR"
    CODEX_INSTALL_DIR="$install_dir" '${bash}/bin/bash' '${sourceRoot}/install.sh' '${codexDmg}'
    patch_nixos_runtime "$install_dir"
    printf '%s\n' "$EXPECTED_STAMP" > "$build_root/build-stamp"

    rm -rf "$APP_DIR"
    mv "$install_dir" "$APP_DIR"
    mv "$build_root/build-stamp" "$STAMP_FILE"
}

if ! app_ready || ! stamp_matches; then
    materialize_app
fi

exec '${bash}/bin/bash' "$APP_DIR/start.sh" "$@"
SCRIPT

    chmod 0755 "$out/bin/codex-desktop"

    sed \
      -e "s|/usr/bin/codex-desktop|$out/bin/codex-desktop|g" \
      -e "s|/usr/share/applications/codex-desktop.desktop|$out/share/applications/codex-desktop.desktop|g" \
      "${desktopFile}" > "$out/share/applications/codex-desktop.desktop"

    cp "${iconFile}" "$out/share/icons/hicolor/256x256/apps/codex-desktop.png"
  '';

  meta = with lib; {
    description = "Nix package wrapper for Codex Desktop on Linux generated from the upstream DMG";
    homepage = "https://github.com/ilysenko/codex-desktop-linux";
    license = licenses.unfreeRedistributable;
    maintainers = [];
    mainProgram = "codex-desktop";
    platforms = platforms.linux;
  };
}
