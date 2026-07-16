#!/usr/bin/env bash
# Baut VideoTools-GUI.app aus main.swift + Info.plist.
# Bündelt ffmpeg/ffprobe MIT allen dynamischen Bibliotheken in die .app,
# damit das Bundle eigenständig funktioniert (auch ohne Homebrew).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/../VideoTools-GUI.app"
BIN="$APP/Contents/MacOS/VideoTools"
RES="$APP/Contents/Resources"
LIBS="$APP/Contents/Frameworks"

echo "▶ Erzeuge App-Bundle unter $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES" "$LIBS"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"

# App-Icon
ICON_SRC="$HERE/../MyIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$RES/AppIcon.icns"
    echo "    ✓ Icon: $ICON_SRC → Resources/AppIcon.icns"
else
    echo "    ⚠ Kein Icon gefunden unter $ICON_SRC"
fi

echo "▶ Kompiliere main.swift → $BIN"
swiftc \
  -O \
  -target arm64-apple-macos14 \
  -parse-as-library \
  -o "$BIN" \
  "$HERE/main.swift"
chmod +x "$BIN"

# ─────────────────────────────────────────────────────────────────────────
# Dylib-Bundler: kopiert rekursiv alle nicht-System dylibs und patcht die
# Install-Names via install_name_tool. Ergebnis: voll autarkes Bundle.
# ─────────────────────────────────────────────────────────────────────────
resolve_path() {
    # macOS-kompatibles readlink -f
    python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$1"
}

# Globale Liste verarbeiteter Dateien (über Leerzeichen getrennt)
PROCESSED=""

bundle_deps() {
    local file="$1"
    # Schon gesehen?
    case " $PROCESSED " in *" $file "*) return 0 ;; esac
    PROCESSED="$PROCESSED $file"

    chmod u+w "$file"

    # otool listet Dependencies; erster Eintrag bei dylibs ist die eigene ID.
    # Filter: alles aus /usr/lib und /System bleibt unangetastet (Systemlibs).
    local deps
    deps=$(otool -L "$file" | tail -n +2 | awk '{print $1}' \
            | grep -vE '^/(usr/lib|System)/' || true)

    local dep depname real target
    for dep in $deps; do
        depname="$(basename "$dep")"
        # Self-Reference (dylib ID zeigt auf sich selbst) überspringen
        if [[ "$depname" == "$(basename "$file")" && "$file" == *"/$depname" ]]; then
            install_name_tool -id "@rpath/$depname" "$file" 2>/dev/null || true
            continue
        fi

        target="$LIBS/$depname"
        if [[ ! -f "$target" ]]; then
            real=""
            if [[ -f "$dep" ]]; then
                real="$(resolve_path "$dep")"
            else
                # @rpath / @loader_path / @executable_path → im Homebrew-Tree suchen
                for candidate in \
                    "/opt/homebrew/lib/$depname" \
                    "/opt/homebrew/opt/"*/lib/"$depname" \
                    "/usr/local/lib/$depname" \
                    "/usr/local/opt/"*/lib/"$depname"
                do
                    if [[ -f "$candidate" ]]; then
                        real="$(resolve_path "$candidate")"
                        break
                    fi
                done
            fi
            if [[ -z "$real" || ! -f "$real" ]]; then
                echo "    ⚠ konnte $dep nicht auflösen – überspringe"
                continue
            fi
            cp "$real" "$target"
            chmod u+w "$target"
            install_name_tool -id "@rpath/$depname" "$target" 2>/dev/null || true
            # Rekursiv dessen Deps verarbeiten
            bundle_deps "$target"
        fi

        # Referenz in der aktuellen Datei umbiegen
        install_name_tool -change "$dep" "@rpath/$depname" "$file" 2>/dev/null || true
    done
}

bundle_tool() {
    local tool="$1"
    local src=""
    for cand in /opt/homebrew/bin/$tool /usr/local/bin/$tool /usr/bin/$tool; do
        [[ -x "$cand" ]] && { src="$cand"; break; }
    done
    [[ -z "$src" ]] && src="$(command -v $tool || true)"

    if [[ -z "$src" || ! -x "$src" ]]; then
        echo "    ⚠ $tool nicht gefunden – App nutzt zur Laufzeit die Systeminstallation."
        return 0
    fi

    local real
    real="$(resolve_path "$src")"
    local dest="$RES/$tool"
    cp "$real" "$dest"
    chmod u+w "$dest"

    # @rpath so setzen, dass dylibs in Contents/Frameworks gefunden werden.
    # Resources/ liegt parallel zu Frameworks/ → ../Frameworks/ vom Binary aus.
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$dest" 2>/dev/null || true

    bundle_deps "$dest"
    echo "    ✓ $tool ← $real"
}

echo "▶ Bündle ffmpeg/ffprobe + alle dynamischen Abhängigkeiten"
bundle_tool ffmpeg
bundle_tool ffprobe

# Ad-hoc Signatur (rekursiv, damit auch Frameworks/*.dylib signiert sind)
echo "▶ Ad-hoc codesign (rekursiv)"
# Zuerst innere Libs signieren, dann das Bundle
find "$LIBS" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 2>/dev/null | \
    xargs -0 -I{} codesign --force --sign - --timestamp=none {} 2>/dev/null || true
codesign --force --sign - "$RES/ffmpeg"  2>/dev/null || true
codesign --force --sign - "$RES/ffprobe" 2>/dev/null || true
codesign --force --deep --sign - "$APP"  2>/dev/null || true

du -sh "$APP" | awk '{print "▶ Bundle-Größe: "$1}'
ls "$LIBS" 2>/dev/null | wc -l | awk '{print "▶ gebündelte dylibs: "$1}'
echo "✓ Fertig: $APP"
