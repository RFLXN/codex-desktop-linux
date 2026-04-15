{ lib
, stdenv
, stdenvNoCC
, autoPatchelfHook
, makeWrapper
, bash
, nodejs
, python3
, p7zip
, patchelf
, gcc
, unzip
, gnumake
, coreutils
, cacert
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

  buildSource = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./assets/codex.png
      ./nix/build-codex-app.sh
      ./scripts/patch-linux-window-ui.js
    ];
  };

  electronVersion = "40.8.5";
  electronMeta =
    {
      x86_64-linux = {
        arch = "x64";
        hash = "sha256-O85u5OTkgffObQvjhPbFOc4W4Lm39GEVrsZRZ3D2wm0=";
      };
      aarch64-linux = {
        arch = "arm64";
        hash = "sha256-WvAHPFKo3HKeEYNAtfUMSykyvZS6mS4cU4D+FUUzA3M=";
      };
    }.${stdenv.hostPlatform.system} or (throw "Unsupported system for Codex Desktop: ${stdenv.hostPlatform.system}");

  electronZip = fetchurl {
    url = "https://github.com/electron/electron/releases/download/v${electronVersion}/electron-v${electronVersion}-linux-${electronMeta.arch}.zip";
    hash = electronMeta.hash;
  };

  electronLibs = [
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

  runtimePath = lib.makeBinPath [
    bash
    nodejs
    python3
    coreutils
    diffutils
    findutils
    gnugrep
    gnused
    libnotify
    procps
    util-linux
  ];

  buildStamp = builtins.hashString "sha256" ''
    source=${toString buildSource}
    dmg=${toString codexDmg}
    electron=${toString electronZip}
    electronVersion=${electronVersion}
  '';

  version = "unstable-${builtins.substring 0 12 buildStamp}";

  codexAppRaw = stdenvNoCC.mkDerivation {
    pname = "codex-desktop-app";
    inherit version;

    src = buildSource;
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;

    nativeBuildInputs = [
      bash
      nodejs
      python3
      p7zip
      patchelf
      gcc
      unzip
      gnumake
      coreutils
      cacert
      diffutils
      findutils
      gnugrep
      gnused
    ];

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-tpMgZaeSyvRXHB3lTf7Kkj/SJuovTbrEG7flfE8K/bI=";
    preferLocalBuild = true;
    allowSubstitutes = false;

    installPhase = ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      export NIX_SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
      export SSL_CERT_FILE="$NIX_SSL_CERT_FILE"
      export NODE_EXTRA_CA_CERTS="$NIX_SSL_CERT_FILE"
      export npm_config_cache="$TMPDIR/npm-cache"
      export npm_config_cafile="$NIX_SSL_CERT_FILE"
      export npm_config_update_notifier=false
      export npm_config_fund=false
      export npm_config_audit=false
      export npm_config_progress=false
      unset NIX_LDFLAGS NIX_CFLAGS_COMPILE NIX_CFLAGS_LINK LDFLAGS CFLAGS CXXFLAGS

      export SOURCE_ROOT="${buildSource}"
      export DMG_PATH="${codexDmg}"
      export ELECTRON_ZIP="${electronZip}"
      export ELECTRON_VERSION="${electronVersion}"
      export ICON_SOURCE="${buildSource}/assets/codex.png"
      export PATCH_SCRIPT="${buildSource}/scripts/patch-linux-window-ui.js"
      export INSTALL_DIR="$out"
      export NIX_BASH="/bin/bash"

      "${bash}/bin/bash" "${buildSource}/nix/build-codex-app.sh"
    '';
  };
in
stdenv.mkDerivation {
  pname = "codex-desktop";
  inherit version;

  src = codexAppRaw;
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
    bash
    coreutils
    gnused
  ];

  buildInputs = electronLibs;

  installPhase = ''
    runHook preInstall

    mkdir -p \
      "$out/lib" \
      "$out/bin" \
      "$out/share/applications" \
      "$out/share/icons/hicolor/256x256/apps"

    cp -aT "$src" "$out/lib/codex-desktop"

    substituteInPlace "$out/lib/codex-desktop/start.sh" \
      --replace-fail '#!/bin/bash' '#!${bash}/bin/bash'

    makeWrapper "$out/lib/codex-desktop/start.sh" "$out/bin/codex-desktop" \
      --prefix PATH : "${runtimePath}" \
      --set-default CHROME_DESKTOP "codex-desktop.desktop" \
      --set-default BAMF_DESKTOP_FILE_HINT "$out/share/applications/codex-desktop.desktop"

    sed \
      -e "s|Exec=.*|Exec=$out/bin/codex-desktop|g" \
      "${sourceRoot}/packaging/linux/codex-desktop.desktop" > "$out/share/applications/codex-desktop.desktop"

    cp "${sourceRoot}/assets/codex.png" "$out/share/icons/hicolor/256x256/apps/codex-desktop.png"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Codex Desktop for Linux rebuilt from the upstream macOS DMG";
    homepage = "https://github.com/ilysenko/codex-desktop-linux";
    license = licenses.unfreeRedistributable;
    maintainers = [];
    mainProgram = "codex-desktop";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
