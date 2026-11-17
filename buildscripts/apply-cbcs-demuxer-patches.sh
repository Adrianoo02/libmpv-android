#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FFMPEG_DIR="$SCRIPT_DIR/deps/ffmpeg"
PATCH_URL="https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/25965.patch"

EXPECTED_COMMITS=(
  "ca251548bd61c9c615d2ff0143eea417b33f038a"
  "8019c5d2f9b7c764239b021b52c1bdb49fb13872"
  "c95ba3d34fdd1fc125e3b51c2f6777c72ff766e8"
  "71f6250d7ffe7a67d79167f72def406231dfcbe0"
)

if [[ ! -d "$FFMPEG_DIR/.git" ]]; then
  echo "ERROR: Nie znaleziono repozytorium FFmpeg: $FFMPEG_DIR" >&2
  echo "Najpierw uruchom buildscripts/download.sh." >&2
  exit 1
fi

FFMPEG_TAG="$(git -C "$FFMPEG_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
if [[ "$FFMPEG_TAG" != "n9.0.2" ]]; then
  echo "ERROR: Oczekiwano FFmpeg n9.0.2, wykryto: ${FFMPEG_TAG:-brak tagu}" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Pobieranie serii poprawek FFmpeg CBCS..."
curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 30 \
  "$PATCH_URL" -o "$TMP_DIR/ffmpeg-25965.patch"

python3 - "$TMP_DIR/ffmpeg-25965.patch" "$TMP_DIR/cbcs-demuxer.mbox" <<'PY'
import re
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
text = source_path.read_text(encoding="utf-8", errors="replace")

expected = [
    "ca251548bd61c9c615d2ff0143eea417b33f038a",
    "8019c5d2f9b7c764239b021b52c1bdb49fb13872",
    "c95ba3d34fdd1fc125e3b51c2f6777c72ff766e8",
    "71f6250d7ffe7a67d79167f72def406231dfcbe0",
]

markers = list(re.finditer(
    r"(?m)^From ([0-9a-f]{40}) Mon Sep 17 00:00:00 2001\s*$",
    text
))

if len(markers) < 4:
    print("Nie znaleziono czterech oczekiwanych commitow w odpowiedzi PR.", file=sys.stderr)
    print("Poczatek odpowiedzi:", file=sys.stderr)
    print("\n".join(text.splitlines()[:30]), file=sys.stderr)
    raise SystemExit(2)

actual = [m.group(1) for m in markers[:4]]
if actual != expected:
    print("Odmowa zastosowania nieoczekiwanej wersji poprawek CBCS.", file=sys.stderr)
    print("Otrzymane identyfikatory commitow:", *actual, sep="\n  ", file=sys.stderr)
    raise SystemExit(3)

start = markers[0].start()
end = markers[4].start() if len(markers) > 4 else len(text)
series = text[start:end]

if "Subject: [PATCH 04/10]" not in series:
    raise SystemExit("Nie znaleziono czwartego patcha serii.")

output_path.write_text(series, encoding="utf-8", newline="\n")
print("Zweryfikowano cztery poprawki demuksera CBCS.")
PY

echo "Nakladanie poprawek na FFmpeg n9.0.2..."
git -C "$FFMPEG_DIR" -c user.name="WAExplorer CBCS build" -c user.email="actions@users.noreply.github.com" am --keep-cr "$TMP_DIR/cbcs-demuxer.mbox"

PATCHED_FILES="$(git -C "$FFMPEG_DIR" diff HEAD~4 HEAD --name-only)"
if [[ "$PATCHED_FILES" != "libavformat/mov.c" ]]; then
  echo "ERROR: Nieoczekiwany zestaw plikow po nalozeniu poprawek: $PATCHED_FILES" >&2
  exit 1
fi

echo
echo "Zastosowane poprawki FFmpeg:"
git -C "$FFMPEG_DIR" --no-pager log -4 --oneline
echo
echo "Gotowe: zastosowano cztery poprawki demuksera CBCS."
