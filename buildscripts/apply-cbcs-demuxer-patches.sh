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

echo "Pobieranie aktualnej serii poprawek FFmpeg CBCS..."
curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 30 \
  "$PATCH_URL" -o "$TMP_DIR/ffmpeg-25965.patch"

python3 - "$TMP_DIR/ffmpeg-25965.patch" "$TMP_DIR/cbcs-demuxer.mbox" "$TMP_DIR/patch-count.txt" <<'PY'
import re
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
count_path = Path(sys.argv[3])
text = source_path.read_text(encoding="utf-8", errors="replace")

markers = list(re.finditer(
    r"(?m)^From ([0-9a-f]{40}) Mon Sep 17 00:00:00 2001[ 	]*$",
    text
))
if len(markers) < 3:
    raise SystemExit("Aktualna odpowiedz PR nie zawiera oczekiwanej liczby commitow.")

# Nie opieramy sie na numerach [PATCH n/10], bo autor zmienil serie
# z 10 na 12 commitow. Wybieramy po tytule i pliku docelowym.
selected = []
subjects = []
for index, marker in enumerate(markers):
    start = marker.start()
    end = markers[index + 1].start() if index + 1 < len(markers) else len(text)
    section = text[start:end]
    header = section.split("\n\n", 1)[0]

    subject_lines = []
    collecting = False
    for line in header.splitlines():
        if line.startswith("Subject: "):
            collecting = True
            subject_lines.append(line[len("Subject: "):].strip())
        elif collecting and line.startswith((" ", "\t")):
            subject_lines.append(line.strip())
        elif collecting:
            break

    subject = re.sub(r"\s+", " ", " ".join(subject_lines)).strip()
    if not subject:
        continue

    # Demukser MP4: interesuja nas tylko zmiany w mov.c odnoszace sie
    # do tenc/CBC/CENC/CBCS. Pomin muxer i testy, niepotrzebne do odtwarzania.
    paths = re.findall(r"(?m)^diff --git a/([^ ]+) b/([^ ]+)$", section)
    path_set = {(a, b) for a, b in paths}
    normalized_subject = subject.lower()
    relevant_topic = any(token in normalized_subject for token in
                         ("tenc", "cbcs", "cbc", "cenc"))
    only_demuxer = bool(path_set) and path_set == {
        ("libavformat/mov.c", "libavformat/mov.c")
    }

    if relevant_topic and only_demuxer:
        selected.append(section)
        subjects.append(subject)

if len(selected) < 2:
    print("Nie znaleziono wystarczajacej liczby poprawek demuksera.", file=sys.stderr)
    print("Naglowki pobranej serii:", file=sys.stderr)
    for marker in markers:
        line = text[marker.start():].splitlines()[2:4]
        print("  " + " | ".join(line), file=sys.stderr)
    raise SystemExit(4)

joined_subjects = " ".join(subjects).lower()
if "tenc" not in joined_subjects:
    raise SystemExit("Wybrana seria nie zawiera poprawki parsera tenc.")
if not any(token in joined_subjects for token in ("cbcs", "cbc")):
    raise SystemExit("Wybrana seria nie zawiera poprawki deszyfrowania CBC/CBCS.")

output_path.write_text("".join(selected), encoding="utf-8", newline="\n")
count_path.write_text(str(len(selected)), encoding="ascii")
print(f"Wybrano {len(selected)} poprawek demuksera:")
for subject in subjects:
    print(" - " + subject)
print("Wszystkie zmiany ograniczaja sie do libavformat/mov.c.")
PY

PATCH_COUNT="$(cat "$TMP_DIR/patch-count.txt")"
echo "Nakladanie $PATCH_COUNT poprawek na FFmpeg n9.0.2..."
git -C "$FFMPEG_DIR" -c user.name="WAExplorer CBCS build" -c user.email="actions@users.noreply.github.com" am --keep-cr "$TMP_DIR/cbcs-demuxer.mbox"

PATCHED_FILES="$(git -C "$FFMPEG_DIR" diff "HEAD~$PATCH_COUNT" HEAD --name-only | sort -u)"
if [[ "$PATCHED_FILES" != "libavformat/mov.c" ]]; then
  echo "ERROR: Nieoczekiwany zestaw plikow po nalozeniu poprawek: $PATCHED_FILES" >&2
  exit 1
fi

if ! grep -q "crypt_blocks" "$FFMPEG_DIR/libavformat/mov.c"; then
  echo "ERROR: Brak oczekiwanej logiki wzorca CBCS (crypt_blocks)." >&2
  exit 1
fi

if ! grep -q "sample size is not a multiple of 16" "$FFMPEG_DIR/libavformat/mov.c"; then
  echo "ERROR: Brak walidacji rozmiaru danych szyfrowanych CBC/CBCS." >&2
  exit 1
fi

echo
echo "Zastosowane poprawki FFmpeg:"
git -C "$FFMPEG_DIR" --no-pager log "-$PATCH_COUNT" --oneline
echo
echo "Gotowe: poprawki demuksera CBCS zostaly zastosowane i zweryfikowane."
