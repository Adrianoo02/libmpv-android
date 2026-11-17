#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FFMPEG_DIR="$SCRIPT_DIR/deps/ffmpeg"

if [[ ! -d "$FFMPEG_DIR/.git" ]]; then
  echo "ERROR: Nie znaleziono repozytorium FFmpeg: $FFMPEG_DIR" >&2
  echo "Najpierw uruchom buildscripts/download.sh." >&2
  exit 1
fi

FFMPEG_TAG="$(git -C "$FFMPEG_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
if [[ "$FFMPEG_TAG" != "n9.0.2" ]]; then
  echo "ERROR: Oczekiwano FFmpeg n9.0.2, wykryto: $FFMPEG_TAG" >&2
  exit 1
fi

echo "Dostosowanie demuksera MOV do FFmpeg n9.0.2..."
python3 - "$FFMPEG_DIR/libavformat/mov.c" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")

def find_function_end(text: str, signature: str) -> tuple[int, int]:
    starts = [i for i in range(len(text)) if text.startswith(signature, i)]
    if len(starts) != 1:
        raise SystemExit(
            f"Oczekiwano jednej funkcji {signature!r}, znaleziono: {len(starts)}"
        )

    start = starts[0]
    opening = text.find("{", start)
    if opening < 0:
        raise SystemExit(f"Brak poczatku ciala funkcji: {signature}")

    depth = 0
    state = "normal"
    escaped = False
    i = opening

    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""

        if state == "line_comment":
            if ch == "\n":
                state = "normal"
        elif state == "block_comment":
            if ch == "*" and nxt == "/":
                state = "normal"
                i += 1
        elif state == "string":
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                state = "normal"
        elif state == "char":
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == "'":
                state = "normal"
        else:
            if ch == "/" and nxt == "/":
                state = "line_comment"
                i += 1
            elif ch == "/" and nxt == "*":
                state = "block_comment"
                i += 1
            elif ch == '"':
                state = "string"
            elif ch == "'":
                state = "char"
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return start, i + 1
        i += 1

    raise SystemExit(f"Nie znaleziono konca funkcji: {signature}")

def replace_function(text: str, signature: str, replacement: str) -> str:
    start, end = find_function_end(text, signature)
    return text[:start] + replacement + text[end:]

tenc = r'''static int mov_read_tenc(MOVContext *c, AVIOContext *pb, MOVAtom atom)
{
    AVStream *st;
    MOVStreamContext *sc;
    AVEncryptionInfo *info;
    unsigned int version, pattern, is_protected, iv_size;
    int legacy_layout;
    int bytes_read;

    if (c->fc->nb_streams < 1)
        return 0;
    st = c->fc->streams[c->fc->nb_streams-1];
    sc = st->priv_data;

    if (sc->pseudo_stream_id != 0) {
        av_log(c->fc, AV_LOG_ERROR, "tenc atom are only supported in first sample descriptor\n");
        return AVERROR_PATCHWELCOME;
    }

    if (!sc->cenc.default_encrypted_sample) {
        sc->cenc.default_encrypted_sample = av_encryption_info_alloc(0, 16, 16);
        if (!sc->cenc.default_encrypted_sample) {
            return AVERROR(ENOMEM);
        }
    }
    info = sc->cenc.default_encrypted_sample;

    if (atom.size < 23)
        return AVERROR_INVALIDDATA;

    version = avio_r8(pb); /* version */
    avio_rb24(pb); /* flags */

    avio_r8(pb); /* reserved */
    pattern = avio_r8(pb);
    is_protected = avio_r8(pb);

    /* ISO/IEC 23001-7 layout: reserved, default_IsProtected,
     * default_Per_Sample_IV_Size, default_KID, [constant IV],
     * default_Crypt_Byte_Block, default_Skip_Byte_Block. */
    if (pattern <= 1 &&
        (is_protected == 0 || is_protected == 8 || is_protected == 16)) {
        legacy_layout = 0;
        iv_size = is_protected;
        is_protected = pattern;
    } else {
        /* Legacy FFmpeg layout: reserved, pattern,
         * default_IsProtected, default_Per_Sample_IV_Size,
         * default_KID, with a nibble-packed pattern byte. */
        legacy_layout = 1;
        if (version > 0) {
            info->crypt_byte_block = pattern >> 4;
            info->skip_byte_block = pattern & 0xf;
        }
        iv_size = avio_r8(pb);
    }

    if (is_protected && !sc->cenc.encryption_index) {
        // The whole stream should be by-default encrypted.
        sc->cenc.encryption_index = av_mallocz(sizeof(MOVEncryptionIndex));
        if (!sc->cenc.encryption_index)
            return AVERROR(ENOMEM);
    }

    if (iv_size != 0 && iv_size != 8 && iv_size != 16) {
        av_log(c->fc, AV_LOG_ERROR, "invalid per-sample IV size value\n");
        return AVERROR_INVALIDDATA;
    }
    sc->cenc.per_sample_iv_size = iv_size;

    if (avio_read(pb, info->key_id, 16) != 16) {
        av_log(c->fc, AV_LOG_ERROR, "failed to read the default key ID\n");
        return AVERROR_INVALIDDATA;
    }

    if (legacy_layout) {
        if (is_protected && !sc->cenc.per_sample_iv_size) {
            iv_size = avio_r8(pb);
            if (iv_size != 8 && iv_size != 16) {
                av_log(c->fc, AV_LOG_ERROR, "invalid default_constant_IV_size in tenc atom\n");
                return AVERROR_INVALIDDATA;
            }

            if (avio_read(pb, info->iv, iv_size) != iv_size) {
                av_log(c->fc, AV_LOG_ERROR, "failed to read the default IV\n");
                return AVERROR_INVALIDDATA;
            }
        }
        return 0;
    }

    bytes_read = 4 + 1 + 1 + 1 + 16;

    if (is_protected && !iv_size) {
        int constant_iv_size = avio_r8(pb);
        bytes_read += 1;
        if (constant_iv_size != 8 && constant_iv_size != 16) {
            av_log(c->fc, AV_LOG_ERROR, "invalid default_constant_IV_size in tenc atom\n");
            return AVERROR_INVALIDDATA;
        }

        if (avio_read(pb, info->iv, constant_iv_size) != constant_iv_size) {
            av_log(c->fc, AV_LOG_ERROR, "failed to read the default IV\n");
            return AVERROR_INVALIDDATA;
        }
        bytes_read += constant_iv_size;
    }

    if (bytes_read + 2 <= atom.size) {
        info->crypt_byte_block = avio_r8(pb);
        info->skip_byte_block = avio_r8(pb);
    }

    return 0;
}'''

cbc1_signature = "static int cbc1_scheme_decrypt("
cbc1_start, cbc1_end = find_function_end(source, cbc1_signature)
cbc1 = source[cbc1_start:cbc1_end]
cbc1_old = r'''    if (!sample->subsample_count) {
        /* decrypt the whole packet */
        av_aes_crypt(sc->cenc.aes_ctx, input, input, size/16, iv, 1);
        return 0;
    }'''
cbc1_new = r'''    if (!sample->subsample_count) {
        /* decrypt the whole packet */
        if (size % 16) {
            av_log(c->fc, AV_LOG_ERROR, "sample size is not a multiple of 16\n");
            return AVERROR_INVALIDDATA;
        }
        av_aes_crypt(sc->cenc.aes_ctx, input, input, size/16, iv, 1);
        return 0;
    }'''
if cbc1.count(cbc1_old) != 1:
    raise SystemExit("Nie znaleziono jednoznacznego bloku pelnego CBC1 do poprawienia.")
cbc1 = cbc1.replace(cbc1_old, cbc1_new, 1)
source = source[:cbc1_start] + cbc1 + source[cbc1_end:]

cbcs = r'''static int cbcs_scheme_decrypt(MOVContext *c, MOVStreamContext *sc, AVEncryptionInfo *sample, uint8_t *input, int size)
{
    int i, ret, rem_bytes, crypt_blocks;
    uint8_t iv[16];
    uint8_t *data;
    uint8_t decryption_key[16];

    if (!sc->cenc.aes_ctx) {
        ret = get_key_from_kid(decryption_key, sizeof(decryption_key), c, sample);
        if (ret < 0) {
            return ret;
        }

        /* initialize the cipher */
        sc->cenc.aes_ctx = av_aes_alloc();
        if (!sc->cenc.aes_ctx) {
            return AVERROR(ENOMEM);
        }

        ret = av_aes_init(sc->cenc.aes_ctx, decryption_key, 16 * 8, 1);
        if (ret < 0) {
            return ret;
        }
    }

    /* whole-sample encryption */
    if (!sample->subsample_count) {
        memcpy(iv, sample->iv, 16);
        if (!sample->crypt_byte_block && !sample->skip_byte_block) {
            /* zero pattern means full-sample CBC */
            if (size % 16) {
                av_log(c->fc, AV_LOG_ERROR, "sample size is not a multiple of 16\n");
                return AVERROR_INVALIDDATA;
            }
            av_aes_crypt(sc->cenc.aes_ctx, input, input, size / 16, iv, 1);
        } else {
            /* apply the crypt/skip pattern to the whole sample */
            data = input;
            rem_bytes = size;
            while (rem_bytes >= 16) {
                crypt_blocks = FFMIN(sample->crypt_byte_block, rem_bytes / 16);
                av_aes_crypt(sc->cenc.aes_ctx, data, data, crypt_blocks, iv, 1);
                data += 16 * crypt_blocks;
                rem_bytes -= 16 * crypt_blocks;
                data += FFMIN(16 * sample->skip_byte_block, rem_bytes);
                rem_bytes -= FFMIN(16 * sample->skip_byte_block, rem_bytes);
            }
        }
        return 0;
    }

    for (i = 0; i < sample->subsample_count; i++) {
        if (sample->subsamples[i].bytes_of_clear_data + (int64_t)sample->subsamples[i].bytes_of_protected_data > size) {
            av_log(c->fc, AV_LOG_ERROR, "subsample size exceeds the packet size left\n");
            return AVERROR_INVALIDDATA;
        }

        /* skip the clear bytes */
        input += sample->subsamples[i].bytes_of_clear_data;
        size -= sample->subsamples[i].bytes_of_clear_data;

        /* decrypt the encrypted bytes */
        memcpy(iv, sample->iv, 16);
        data = input;
        rem_bytes = sample->subsamples[i].bytes_of_protected_data;
        if (!sample->crypt_byte_block && !sample->skip_byte_block) {
            if (rem_bytes % 16) {
                av_log(c->fc, AV_LOG_ERROR, "subsample BytesOfProtectedData is not a multiple of 16\n");
                return AVERROR_INVALIDDATA;
            }
            av_aes_crypt(sc->cenc.aes_ctx, data, data, rem_bytes / 16, iv, 1);
        } else {
            while (rem_bytes >= 16) {
                crypt_blocks = FFMIN(sample->crypt_byte_block, rem_bytes / 16);
                av_aes_crypt(sc->cenc.aes_ctx, data, data, crypt_blocks, iv, 1);
                data += 16 * crypt_blocks;
                rem_bytes -= 16 * crypt_blocks;
                data += FFMIN(16 * sample->skip_byte_block, rem_bytes);
                rem_bytes -= FFMIN(16 * sample->skip_byte_block, rem_bytes);
            }
        }
        input += sample->subsamples[i].bytes_of_protected_data;
        size -= sample->subsamples[i].bytes_of_protected_data;
    }

    if (size > 0) {
        av_log(c->fc, AV_LOG_ERROR, "leftover packet bytes after subsample processing\n");
        return AVERROR_INVALIDDATA;
    }

    return 0;
}'''

source = replace_function(source, "static int mov_read_tenc(", tenc)
source = replace_function(source, "static int cbcs_scheme_decrypt(", cbcs)

# Tymczasowa diagnostyka: wskaz, ktory atom MOV powoduje blad naglowka.
diag_old = r'''            int err = parse(c, pb, a);
            if (err < 0) {
                c->atom_depth --;
                return err;
            }'''
diag_new = r'''            int err = parse(c, pb, a);
            if (err < 0) {
                av_log(c->fc, AV_LOG_ERROR,
                       "WAEXPLORER_DIAG: atom %s size=%"PRId64" offset=%"PRId64" parse_error=%d\n",
                       av_fourcc2str(a.type), a.size, start_pos, err);
                c->atom_depth --;
                return err;
            }'''
if source.count(diag_old) != 1:
    raise SystemExit("Nie znaleziono jednoznacznego bloku mov_read_default do diagnostyki.")
source = source.replace(diag_old, diag_new, 1)

tenc_size_old = '''    if (atom.size < 23)
        return AVERROR_INVALIDDATA;'''
tenc_size_new = '''    if (atom.size < 23) {
        av_log(c->fc, AV_LOG_ERROR,
               "WAEXPLORER_DIAG: tenc too small, atom_size=%"PRId64"\\n", atom.size);
        return AVERROR_INVALIDDATA;
    }'''
if source.count(tenc_size_old) != 1:
    raise SystemExit("Nie znaleziono kontroli rozmiaru tenc.")
source = source.replace(tenc_size_old, tenc_size_new, 1)

tenc_raw_old = '''    pattern = avio_r8(pb);
    is_protected = avio_r8(pb);

    /* ISO/IEC 23001-7 layout:'''
tenc_raw_new = '''    pattern = avio_r8(pb);
    is_protected = avio_r8(pb);
    av_log(c->fc, AV_LOG_ERROR,
           "WAEXPLORER_DIAG: tenc raw size=%"PRId64" version=%u field2=%u field3=%u\\\\n",
           atom.size, version, pattern, is_protected);

    /* ISO/IEC 23001-7 layout:'''
if source.count(tenc_raw_old) != 1:
    raise SystemExit("Nie znaleziono miejsca do diagnostyki pol tenc.")
source = source.replace(tenc_raw_old, tenc_raw_new, 1)

tenc_parsed_old = '''        iv_size = avio_r8(pb);
    }

    if (is_protected && !sc->cenc.encryption_index) {'''
tenc_parsed_new = '''        iv_size = avio_r8(pb);
    }
    av_log(c->fc, AV_LOG_ERROR,
           "WAEXPLORER_DIAG: tenc parsed legacy=%d protected=%u iv_size=%u pattern=0x%02x version=%u\\\\n",
           legacy_layout, is_protected, iv_size, pattern, version);

    if (is_protected && !sc->cenc.encryption_index) {'''
if source.count(tenc_parsed_old) != 1:
    raise SystemExit("Nie znaleziono miejsca do diagnostyki wyniku parsera tenc.")
source = source.replace(tenc_parsed_old, tenc_parsed_new, 1)

required = (
    "legacy_layout",
    "crypt_blocks",
    "sample size is not a multiple of 16",
    "subsample BytesOfProtectedData is not a multiple of 16",
)
for token in required:
    if token not in source:
        raise SystemExit(f"Brak wymaganej logiki po zmianach: {token}")

path.write_text(source, encoding="utf-8", newline="\n")
print("Zmieniono funkcje mov_read_tenc, cbc1_scheme_decrypt i cbcs_scheme_decrypt.")
print("Zweryfikowano parser obu ukladow tenc, wzorzec CBCS oraz wyrownanie AES.")
PY

PATCHED_FILES="$(git -C "$FFMPEG_DIR" diff --name-only | sort -u)"
if [[ "$PATCHED_FILES" != "libavformat/mov.c" ]]; then
  echo "ERROR: Nieoczekiwane pliki zmienione w FFmpeg: $PATCHED_FILES" >&2
  exit 1
fi

git -C "$FFMPEG_DIR" diff --check

echo
echo "Podsumowanie zmian FFmpeg:"
git -C "$FFMPEG_DIR" diff --stat
echo
echo "Gotowe: poprawki CBCS zostaly przeniesione bezposrednio na FFmpeg n9.0.2."
