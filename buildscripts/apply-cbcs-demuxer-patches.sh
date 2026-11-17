#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FFMPEG_DIR="$SCRIPT_DIR/deps/ffmpeg"
PATCH_URL="https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/25965.patch"

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

markers = list(re.finditer(
    r"(?m)^From ([0-9a-f]{40}) Mon Sep 17 00:00:00 2001[ \t]*$",
    text
))
if len(markers) < 4:
    raise SystemExit("Nie znaleziono co najmniej czterech commitow w odpowiedzi PR.")

expected_subjects = [
    "avformat/mov: use a local variable for the default tenc encryption info",
    "avformat/mov: fix tenc parsing for ISO/IEC 23001-7 layout",
    "avformat/mov: check sample size alignment before full-sample CBC decryption",
    "avformat/mov: fix cbcs decryption for whole and subsampled samples",
]

found = {}
for index, marker in enumerate(markers):
    start = marker.start()
    end = markers[index + 1].start() if index + 1 < len(markers) else len(text)
    section = text[start:end]
    header = section.split("\n\n", 1)[0]
    normalized_header = re.sub(r"\s+", " ", header)

    matches = [
        subject for subject in expected_subjects
        if subject in normalized_header
    ]
    if not matches:
        continue
    if len(matches) != 1:
        raise SystemExit(f"Niejednoznaczny naglowek poprawki: {normalized_header!r}")

    subject = matches[0]
    if subject in found:
        raise SystemExit(f"Poprawka wystepuje wiecej niz raz: {subject}")

    diff_paths = re.findall(
        r"(?m)^diff --git a/([^ ]+) b/([^ ]+)$",
        section
    )
    if not diff_paths or any(
        a != "libavformat/mov.c" or b != "libavformat/mov.c"
        for a, b in diff_paths
    ):
        raise SystemExit(
            f"Poprawka '{subject}' zmienia nieoczekiwane pliki: {diff_paths!r}"
        )

    found[subject] = section

missing = [subject for subject in expected_subjects if subject not in found]
if missing:
    print("Nie znaleziono wymaganych poprawek:", file=sys.stderr)
    for subject in missing:
        print(" - " + subject, file=sys.stderr)
    raise SystemExit(4)

# Zachowujemy kolejnosc oryginalnej serii PR - wybieramy tylko cztery
# poprawki demuksera, pomijajac zmiany muxera i testow.
selected = []
for index, marker in enumerate(markers):
    start = marker.start()
    end = markers[index + 1].start() if index + 1 < len(markers) else len(text)
    section = text[start:end]
    header = re.sub(r"\s+", " ", section.split("\n\n", 1)[0])
    if any(subject in header for subject in expected_subjects):
        selected.append(section)

if len(selected) != 4:
    raise SystemExit(f"Oczekiwano 4 patchy demuksera, znaleziono {len(selected)}.")

output_path.write_text("".join(selected), encoding="utf-8", newline="\n")
print("Zweryfikowano wszystkie cztery poprawki demuksera CBCS po tytulach.")
print("Wszystkie cztery modyfikuja wylacznie libavformat/mov.c.")
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
