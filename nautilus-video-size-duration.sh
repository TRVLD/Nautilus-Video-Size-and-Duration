#!/usr/bin/env bash
# =============================================================================
#  Nautilus Video Size and Duration — instalator / installer            v2.0.1
#
#  PL: Rozszerzenie Nautilusa (C, API 4, Nautilus 43+) z kolumnami „Czas trwania”,
#      „Szerokość (px)” i „Wysokość (px)” dla plików audio i wideo.
#  EN: Nautilus extension (C, API 4, Nautilus 43+) adding "Duration", "Width (px)"
#      and "Height (px)" columns for audio and video files.
#
#  Fedora / RHEL (dnf) · Debian / Ubuntu / Mint (apt) · Arch / Manjaro (pacman)
#  · openSUSE (zypper, bez testów / untested)
#
#  Użycie / usage:
#    ./nautilus-video-size-duration.sh [install] [--show-by-default] [--lang pl|en]
#    ./nautilus-video-size-duration.sh uninstall
#    ./nautilus-video-size-duration.sh build      # tylko .so do bieżącego katalogu
#    ./nautilus-video-size-duration.sh source     # zapisuje kod C do bieżącego katalogu
#    ./nautilus-video-size-duration.sh help
#
#  Copyright (C) 2026 M.T. Jaroszek
#  SPDX-License-Identifier: EUPL-1.2
#  Licensed under the EUPL, Version 1.2 only. You may not use this work except
#  in compliance with the Licence: https://interoperable-europe.ec.europa.eu/collection/eupl/eupl-text-eupl-12
# =============================================================================
set -euo pipefail

readonly NVSD_VERSION="2.0.1"
readonly EXT_NAME="nautilus-video-size-duration"
readonly SO="lib${EXT_NAME}.so"
readonly OLD_SO="libnautilus-video-duration.so"          # wersja 1 (tylko MP4/MOV)
readonly PC="libnautilus-extension-4"                    # API 4 = Nautilus 43+
readonly SCHEMA="org.gnome.nautilus.list-view"
readonly KEY="default-visible-columns"
readonly NVSD_COLUMNS=(video_duration video_width video_height)
readonly OS_RELEASE="${NVSD_OS_RELEASE:-/etc/os-release}"  # zmienna tylko do testów

# -----------------------------------------------------------------------------
#  Język komunikatów / message language
# -----------------------------------------------------------------------------
UI_LANG=""
ARGS=()
while (( $# )); do
    case "$1" in
        --lang)   UI_LANG="${2:-}"; shift 2 || shift ;;
        --lang=*) UI_LANG="${1#--lang=}"; shift ;;
        *)        ARGS+=("$1"); shift ;;
    esac
done
if [[ -z "$UI_LANG" ]]; then
    case "${NVSD_LANG:-${LANGUAGE:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}}" in
        pl*) UI_LANG=pl ;;
        *)   UI_LANG=en ;;
    esac
fi
[[ "$UI_LANG" == pl || "$UI_LANG" == en ]] || UI_LANG=en

# t "tekst PL" "text EN"
t() { if [[ "$UI_LANG" == pl ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

# msg/warn/die FORMAT [ARG…] — FORMAT to wynik t(), argumenty jak w printf
msg()  { local f="$1"; shift; printf "\033[1;34m==>\033[0m $f\n" "$@"; }
warn() { local f="$1"; shift; printf "\033[1;33m%s\033[0m $f\n" "$(t 'Uwaga:' 'Warning:')" "$@" >&2; }
die()  { local f="$1"; shift; printf "\033[1;31m%s\033[0m $f\n" "$(t 'Błąd:' 'Error:')" "$@" >&2; exit 1; }

BUILD_DIR="$(mktemp -d -t "${EXT_NAME}.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

# -----------------------------------------------------------------------------
#  Kod źródłowy rozszerzenia (C) / extension source code
# -----------------------------------------------------------------------------
write_source() {
cat > "$1" <<'C_SOURCE'
/*
 * Nautilus Video Size and Duration
 *
 * Rozszerzenie menedżera plików Nautilus (API 4, Nautilus 43+) dodające kolumny
 * „Czas trwania”, „Szerokość (px)” i „Wysokość (px)” w widoku listy.
 * A Nautilus extension (API 4, Nautilus 43+) adding "Duration", "Width (px)"
 * and "Height (px)" columns to the list view.
 *
 * Copyright (C) 2026 M.T. Jaroszek
 * SPDX-License-Identifier: EUPL-1.2
 *
 * Licensed under the EUPL, Version 1.2 only (the "Licence"). You may not use
 * this work except in compliance with the Licence. You may obtain a copy of
 * the Licence at: https://interoperable-europe.ec.europa.eu/collection/eupl/eupl-text-eupl-12
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the Licence is distributed on an "AS IS" basis,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *
 * Metadane są czytane bezpośrednio z nagłówków kontenerów (bez GStreamera
 * i ffmpeg), w wątku roboczym. Nautilus sortuje kolumny rozszerzeń funkcją
 * strcmp() na wyświetlanym tekście, więc wartości mają stałą szerokość
 * i są dopełniane spacjami z lewej (kolumny są wyrównane do prawej).
 */
#define _GNU_SOURCE  /* memmem() */
#define G_LOG_DOMAIN "VideoSizeDuration"

#include <nautilus-extension.h>
#include <gio/gio.h>
#include <string.h>

#define VSD_ATTR_DURATION "video_duration"   /* nazwa z wersji 1, zachowana dla zgodności ustawień */
#define VSD_ATTR_WIDTH    "video_width"
#define VSD_ATTR_HEIGHT   "video_height"

#define VSD_MAX_MEM_READ  (16u * 1024u * 1024u)  /* limit wczytania jednej struktury do pamięci */
#define VSD_MAX_TRACKS    64
#define VSD_MAX_LOOP      2000000u               /* bezpiecznik pętli po elementach pliku */
#define VSD_MAX_SECONDS   1e7                    /* > ~115 dni = uszkodzony nagłówek */
#define VSD_MAX_DIMENSION 65535u

#define FOURCC(a, b, c, d) \
    (((guint32) (a) << 24) | ((guint32) (b) << 16) | ((guint32) (c) << 8) | (guint32) (d))

/* ===================================================================== */
/*  Tłumaczenia / translations                                            */
/* ===================================================================== */

typedef struct
{
    const char *lang;
    const char *duration_label, *duration_desc;
    const char *width_label, *width_desc;
    const char *height_label, *height_desc;
} VsdStrings;

/* Pierwszy wpis jest domyślny. Nowy język = nowy wiersz. */
static const VsdStrings vsd_strings[] = {
    { "en",
      "Duration",       "Playing time of audio and video files",
      "Width (px)",     "Video frame width in pixels",
      "Height (px)",    "Video frame height in pixels" },
    { "pl",
      "Czas trwania",   "Czas odtwarzania plików audio i wideo",
      "Szerokość (px)", "Szerokość klatki wideo w pikselach",
      "Wysokość (px)",  "Wysokość klatki wideo w pikselach" },
};

static const VsdStrings *
vsd_pick_strings (void)
{
    /* np. { "pl_PL.UTF-8", "pl_PL", "pl", "C" }, zgodnie z LANGUAGE/LC_ALL/LC_MESSAGES/LANG */
    for (const char *const *name = g_get_language_names (); *name != NULL; name++)
    {
        for (gsize i = 0; i < G_N_ELEMENTS (vsd_strings); i++)
        {
            gsize n = strlen (vsd_strings[i].lang);

            /* strncmp najpierw: dopiero po dopasowaniu wiadomo, że nazwa ma >= n znaków. */
            if (strncmp (*name, vsd_strings[i].lang, n) == 0 &&
                strchr ("_.@", (*name)[n]) != NULL)  /* strchr znajduje też '\0' */
                return &vsd_strings[i];
        }
    }
    return &vsd_strings[0];
}

/* ===================================================================== */
/*  Odczyt pliku i pomocnicze                                             */
/* ===================================================================== */

typedef struct
{
    GInputStream *in;
    GCancellable *cancellable;
    guint64       size;
} VsdReader;

typedef struct
{
    double      seconds;  /* <= 0: nieznany */
    guint32     width;    /* 0: brak obrazu */
    guint32     height;
    const char *format;   /* tylko do logów */
} VsdMedia;

enum
{
    VSD_HINT_MPEG_AUDIO = 1 << 0,  /* .mp3/.aac/audio/mpeg: szukaj ramek także za śmieciami */
};

static inline guint16 rd_be16 (const guint8 *p) { return (guint16) ((p[0] << 8) | p[1]); }
static inline guint32 rd_be24 (const guint8 *p) { return ((guint32) p[0] << 16) | ((guint32) p[1] << 8) | p[2]; }
static inline guint32 rd_be32 (const guint8 *p) { return ((guint32) p[0] << 24) | ((guint32) p[1] << 16) | ((guint32) p[2] << 8) | p[3]; }
static inline guint64 rd_be64 (const guint8 *p) { return ((guint64) rd_be32 (p) << 32) | rd_be32 (p + 4); }
static inline guint16 rd_le16 (const guint8 *p) { return (guint16) (p[0] | (p[1] << 8)); }
static inline guint32 rd_le32 (const guint8 *p) { return p[0] | ((guint32) p[1] << 8) | ((guint32) p[2] << 16) | ((guint32) p[3] << 24); }
static inline guint64 rd_le64 (const guint8 *p) { return rd_le32 (p) | ((guint64) rd_le32 (p + 4) << 32); }

static gboolean
vsd_read_at (VsdReader *r,
             guint64    offset,
             void      *buf,
             gsize      len)
{
    gsize got = 0;

    if (len == 0)
        return TRUE;
    if (offset > (guint64) G_MAXINT64 || offset >= r->size || len > r->size - offset)
        return FALSE;
    if (!g_seekable_seek (G_SEEKABLE (r->in), (goffset) offset, G_SEEK_SET, r->cancellable, NULL))
        return FALSE;
    if (!g_input_stream_read_all (r->in, buf, len, &got, r->cancellable, NULL))
        return FALSE;
    return got == len;
}

/* Czyta do len bajtów (mniej przy końcu pliku). Zwraca liczbę odczytanych. */
static gsize
vsd_read_some (VsdReader *r,
               guint64    offset,
               void      *buf,
               gsize      len)
{
    if (offset >= r->size)
        return 0;
    len = (gsize) MIN ((guint64) len, r->size - offset);
    return vsd_read_at (r, offset, buf, len) ? len : 0;
}

/* Wczytuje fragment do nowego bufora; NULL przy błędzie lub zbyt dużym rozmiarze. */
static guint8 *
vsd_read_alloc (VsdReader *r,
                guint64    offset,
                guint64    len)
{
    guint8 *buf;

    if (len == 0 || len > VSD_MAX_MEM_READ)
        return NULL;
    buf = g_malloc ((gsize) len);
    if (!vsd_read_at (r, offset, buf, (gsize) len))
    {
        g_free (buf);
        return NULL;
    }
    return buf;
}

static void
vsd_media_add_video (VsdMedia *m,
                     guint32   width,
                     guint32   height)
{
    if (width == 0 || height == 0 || width > VSD_MAX_DIMENSION || height > VSD_MAX_DIMENSION)
        return;
    /* Kilka strumieni wideo: pokazujemy największy. */
    if ((guint64) width * height > (guint64) m->width * m->height)
    {
        m->width = width;
        m->height = height;
    }
}

static gboolean
vsd_fourcc_printable (guint32 type)
{
    for (int shift = 0; shift < 32; shift += 8)
    {
        guint8 c = (type >> shift) & 0xff;
        if (c < 0x20 || c > 0x7e)
            return FALSE;
    }
    return TRUE;
}

/* ===================================================================== */
/*  ISO BMFF / QuickTime: MP4, M4V, M4A, MOV, 3GP                         */
/* ===================================================================== */

enum
{
    BOX_FTYP = FOURCC ('f', 't', 'y', 'p'), BOX_MOOV = FOURCC ('m', 'o', 'o', 'v'),
    BOX_MDAT = FOURCC ('m', 'd', 'a', 't'), BOX_FREE = FOURCC ('f', 'r', 'e', 'e'),
    BOX_SKIP = FOURCC ('s', 'k', 'i', 'p'), BOX_WIDE = FOURCC ('w', 'i', 'd', 'e'),
    BOX_PNOT = FOURCC ('p', 'n', 'o', 't'), BOX_UUID = FOURCC ('u', 'u', 'i', 'd'),
    BOX_MVHD = FOURCC ('m', 'v', 'h', 'd'), BOX_TRAK = FOURCC ('t', 'r', 'a', 'k'),
    BOX_TKHD = FOURCC ('t', 'k', 'h', 'd'), BOX_MDIA = FOURCC ('m', 'd', 'i', 'a'),
    BOX_MDHD = FOURCC ('m', 'd', 'h', 'd'), BOX_HDLR = FOURCC ('h', 'd', 'l', 'r'),
    BOX_MINF = FOURCC ('m', 'i', 'n', 'f'), BOX_STBL = FOURCC ('s', 't', 'b', 'l'),
    BOX_STSD = FOURCC ('s', 't', 's', 'd'), BOX_MVEX = FOURCC ('m', 'v', 'e', 'x'),
    BOX_MEHD = FOURCC ('m', 'e', 'h', 'd'), BOX_TREX = FOURCC ('t', 'r', 'e', 'x'),
    BOX_MOOF = FOURCC ('m', 'o', 'o', 'f'), BOX_TRAF = FOURCC ('t', 'r', 'a', 'f'),
    BOX_TFHD = FOURCC ('t', 'f', 'h', 'd'), BOX_TFDT = FOURCC ('t', 'f', 'd', 't'),
    BOX_TRUN = FOURCC ('t', 'r', 'u', 'n'),
    HDLR_VIDE = FOURCC ('v', 'i', 'd', 'e'),
};

typedef struct
{
    guint32 type;
    guint64 start;  /* początek boxa w pliku */
    guint64 size;   /* razem z nagłówkiem */
    guint64 hdr;    /* 8 lub 16 */
} VsdBox;

typedef struct
{
    guint32       type;
    const guint8 *data;  /* zawartość bez nagłówka */
    gsize         len;
} VsdMemBox;

typedef struct
{
    guint32 id;
    guint32 timescale;      /* mdhd */
    guint64 end;            /* koniec ścieżki w jednostkach timescale */
    guint32 trex_duration;  /* mvex/trex: domyślny czas próbki */
} VsdTrack;

typedef struct
{
    guint32  timescale;     /* mvhd */
    guint64  duration;      /* mvhd */
    guint64  mehd;          /* mvex/mehd: łączny czas pliku fragmentowanego */
    gboolean fragmented;    /* moov zawiera mvex */
    gboolean saw_moof;
    GArray  *tracks;        /* VsdTrack */
} VsdMovie;

static gboolean
vsd_bmff_known_box (guint32 type)
{
    switch (type)
    {
        case BOX_FTYP: case BOX_MOOV: case BOX_MDAT: case BOX_FREE:
        case BOX_SKIP: case BOX_WIDE: case BOX_PNOT: case BOX_UUID:
            return TRUE;
        default:
            return FALSE;
    }
}

/* Nagłówek boxa leżącego w [offset, end). FALSE = koniec albo uszkodzenie. */
static gboolean
vsd_read_box (VsdReader *r,
              guint64    offset,
              guint64    end,
              VsdBox    *box)
{
    guint8 h[16];
    guint64 size;

    if (end < offset || end - offset < 8 || !vsd_read_at (r, offset, h, 8))
        return FALSE;

    size = rd_be32 (h);
    box->type = rd_be32 (h + 4);
    box->hdr = 8;

    if (size == 1)
    {
        if (end - offset < 16 || !vsd_read_at (r, offset + 8, h + 8, 8))
            return FALSE;
        size = rd_be64 (h + 8);
        box->hdr = 16;
    }
    else if (size == 0)
    {
        size = end - offset;  /* box sięga do końca rodzica / pliku */
    }

    if (size < box->hdr || size > end - offset)
        return FALSE;

    box->start = offset;
    box->size = size;
    return TRUE;
}

/* Pierwsze dziecko danego typu. */
static gboolean
vsd_find_child (VsdReader    *r,
                const VsdBox *parent,
                guint32       type,
                VsdBox       *child)
{
    guint64 off = parent->start + parent->hdr;
    guint64 end = parent->start + parent->size;

    while (vsd_read_box (r, off, end, child))
    {
        if (child->type == type)
            return TRUE;
        off += child->size;
    }
    return FALSE;
}

static gboolean
vsd_mem_next_box (const guint8 *buf,
                  gsize         len,
                  gsize        *pos,
                  VsdMemBox    *box)
{
    const guint8 *p;
    guint64 size;
    gsize hdr = 8;

    if (*pos > len || len - *pos < 8)
        return FALSE;

    p = buf + *pos;
    size = rd_be32 (p);
    box->type = rd_be32 (p + 4);

    if (size == 1)
    {
        if (len - *pos < 16)
            return FALSE;
        size = rd_be64 (p + 8);
        hdr = 16;
    }
    else if (size == 0)
    {
        size = len - *pos;
    }

    if (size < hdr || size > len - *pos)
        return FALSE;

    box->data = p + hdr;
    box->len = (gsize) size - hdr;
    *pos += (gsize) size;
    return TRUE;
}

static VsdTrack *
vsd_track (VsdMovie *movie,
           guint32   id,
           gboolean  create)
{
    VsdTrack track = { 0 };

    for (guint i = 0; i < movie->tracks->len; i++)
    {
        VsdTrack *t = &g_array_index (movie->tracks, VsdTrack, i);
        if (t->id == id)
            return t;
    }

    if (!create || movie->tracks->len >= VSD_MAX_TRACKS)
        return NULL;

    track.id = id;
    g_array_append_val (movie->tracks, track);
    return &g_array_index (movie->tracks, VsdTrack, movie->tracks->len - 1);
}

/* mvhd i mdhd mają ten sam układ pól timescale/duration. */
static gboolean
vsd_parse_time_header (VsdReader    *r,
                       const VsdBox *box,
                       guint32      *timescale,
                       guint64      *duration)
{
    guint8 p[32];
    guint64 len = box->size - box->hdr;

    if (len < 20 || !vsd_read_at (r, box->start + box->hdr, p, (gsize) MIN (len, sizeof p)))
        return FALSE;

    if (p[0] == 1)
    {
        if (len < 32)
            return FALSE;
        *timescale = rd_be32 (p + 20);
        *duration = rd_be64 (p + 24);
        if (*duration == G_MAXUINT64)
            *duration = 0;  /* „nieznany” */
    }
    else
    {
        *timescale = rd_be32 (p + 12);
        *duration = rd_be32 (p + 16);
        if (*duration == G_MAXUINT32)
            *duration = 0;
    }
    return TRUE;
}

static void
vsd_parse_trak (VsdReader    *r,
                const VsdBox *trak,
                VsdMovie     *movie,
                VsdMedia     *media)
{
    guint64 off = trak->start + trak->hdr;
    guint64 end = trak->start + trak->size;
    guint32 id = 0, timescale = 0, handler = 0;
    guint32 tk_width = 0, tk_height = 0, sd_width = 0, sd_height = 0;
    guint64 duration = 0;
    gboolean have_id = FALSE, have_mdhd = FALSE, rotated = FALSE;
    VsdBox box;

    while (vsd_read_box (r, off, end, &box))
    {
        guint64 len = box.size - box.hdr;

        if (box.type == BOX_TKHD)
        {
            guint8 p[96];
            gsize n = (gsize) MIN (len, sizeof p);

            if (n >= 24 && vsd_read_at (r, box.start + box.hdr, p, n))
            {
                gsize mo = p[0] == 1 ? 52 : 40;  /* przesunięcie macierzy transformacji */

                id = rd_be32 (p + (p[0] == 1 ? 20 : 12));
                have_id = TRUE;
                if (n >= mo + 44)
                {
                    gint32 a = (gint32) rd_be32 (p + mo), b = (gint32) rd_be32 (p + mo + 4);
                    gint32 c = (gint32) rd_be32 (p + mo + 12), d = (gint32) rd_be32 (p + mo + 16);

                    /* Obrót o 90/270° (np. pionowe nagrania z telefonu). */
                    rotated = a == 0 && d == 0 && b != 0 && c != 0;
                    tk_width = rd_be32 (p + mo + 36) >> 16;
                    tk_height = rd_be32 (p + mo + 40) >> 16;
                }
            }
        }
        else if (box.type == BOX_MDIA)
        {
            guint64 o2 = box.start + box.hdr, e2 = box.start + box.size;
            VsdBox child;

            while (vsd_read_box (r, o2, e2, &child))
            {
                if (child.type == BOX_MDHD)
                {
                    have_mdhd = vsd_parse_time_header (r, &child, &timescale, &duration);
                }
                else if (child.type == BOX_HDLR)
                {
                    guint8 p[12];
                    if (child.size - child.hdr >= sizeof p && vsd_read_at (r, child.start + child.hdr, p, sizeof p))
                        handler = rd_be32 (p + 8);
                }
                else if (child.type == BOX_MINF)
                {
                    VsdBox stbl, stsd;
                    guint8 p[44];

                    /* Wymiary w pikselach z pierwszego VisualSampleEntry. */
                    if (vsd_find_child (r, &child, BOX_STBL, &stbl) &&
                        vsd_find_child (r, &stbl, BOX_STSD, &stsd) &&
                        stsd.size - stsd.hdr >= sizeof p &&
                        vsd_read_at (r, stsd.start + stsd.hdr, p, sizeof p) &&
                        rd_be32 (p + 4) >= 1 && rd_be32 (p + 8) >= 36)
                    {
                        sd_width = rd_be16 (p + 40);
                        sd_height = rd_be16 (p + 42);
                    }
                }
                o2 += child.size;
            }
        }
        off += box.size;
    }

    if (have_id && have_mdhd && timescale > 0)
    {
        VsdTrack *t = vsd_track (movie, id, TRUE);
        if (t != NULL)
        {
            t->timescale = timescale;
            t->end = MAX (t->end, duration);
        }
    }

    if (handler == HDLR_VIDE)
    {
        guint32 w = sd_width ? sd_width : tk_width;
        guint32 h = sd_height ? sd_height : tk_height;

        if (rotated)
            vsd_media_add_video (media, h, w);
        else
            vsd_media_add_video (media, w, h);
    }
}

static void
vsd_parse_mvex (VsdReader    *r,
                const VsdBox *mvex,
                VsdMovie     *movie)
{
    guint64 off = mvex->start + mvex->hdr;
    guint64 end = mvex->start + mvex->size;
    VsdBox box;

    while (vsd_read_box (r, off, end, &box))
    {
        guint64 len = box.size - box.hdr;
        guint8 p[24];

        if (box.type == BOX_MEHD && len >= 8 && vsd_read_at (r, box.start + box.hdr, p, (gsize) MIN (len, 12)))
        {
            if (p[0] == 1 && len >= 12)
                movie->mehd = rd_be64 (p + 4);
            else if (p[0] == 0)
                movie->mehd = rd_be32 (p + 4);
        }
        else if (box.type == BOX_TREX && len >= 24 && vsd_read_at (r, box.start + box.hdr, p, 24))
        {
            VsdTrack *t = vsd_track (movie, rd_be32 (p + 4), TRUE);
            if (t != NULL)
                t->trex_duration = rd_be32 (p + 12);
        }
        off += box.size;
    }
}

static void
vsd_parse_moov (VsdReader    *r,
                const VsdBox *moov,
                VsdMovie     *movie,
                VsdMedia     *media)
{
    guint64 off = moov->start + moov->hdr;
    guint64 end = moov->start + moov->size;
    VsdBox box;

    while (vsd_read_box (r, off, end, &box))
    {
        if (g_cancellable_is_cancelled (r->cancellable))
            return;

        switch (box.type)
        {
            case BOX_MVHD:
                vsd_parse_time_header (r, &box, &movie->timescale, &movie->duration);
                break;
            case BOX_TRAK:
                vsd_parse_trak (r, &box, movie, media);
                break;
            case BOX_MVEX:
                movie->fragmented = TRUE;
                vsd_parse_mvex (r, &box, movie);
                break;
            default:
                break;
        }
        off += box.size;
    }
}

static void
vsd_parse_traf (const guint8 *buf,
                gsize         len,
                VsdMovie     *movie)
{
    VsdMemBox box;
    VsdTrack *track;
    gsize pos = 0;
    guint32 track_id = 0, tfhd_flags = 0, default_duration = 0;
    gboolean have_tfhd = FALSE, have_tfdt = FALSE;
    guint64 tfdt = 0, fragment = 0, end;

    /* Przejście 1: tfhd (ścieżka, domyślny czas próbki) i tfdt (czas startu). */
    while (vsd_mem_next_box (buf, len, &pos, &box))
    {
        if (box.type == BOX_TFHD && box.len >= 8)
        {
            gsize p = 8;

            tfhd_flags = rd_be32 (box.data) & 0xffffff;
            track_id = rd_be32 (box.data + 4);
            if (tfhd_flags & 0x000001) p += 8;  /* base-data-offset */
            if (tfhd_flags & 0x000002) p += 4;  /* sample-description-index */
            if ((tfhd_flags & 0x000008) && box.len >= p + 4)
                default_duration = rd_be32 (box.data + p);
            have_tfhd = TRUE;
        }
        else if (box.type == BOX_TFDT && box.len >= 8)
        {
            if (box.data[0] == 1 && box.len >= 12)
            {
                tfdt = rd_be64 (box.data + 4);
                have_tfdt = TRUE;
            }
            else if (box.data[0] == 0)
            {
                tfdt = rd_be32 (box.data + 4);
                have_tfdt = TRUE;
            }
        }
    }

    if (!have_tfhd)
        return;

    track = vsd_track (movie, track_id, FALSE);
    if (track == NULL || track->timescale == 0)
        return;

    if (!(tfhd_flags & 0x000008))
        default_duration = track->trex_duration;

    /* Przejście 2: suma czasów próbek ze wszystkich trun. */
    pos = 0;
    while (vsd_mem_next_box (buf, len, &pos, &box))
    {
        guint32 flags, count;
        gsize p = 8;

        if (box.type != BOX_TRUN || box.len < 8)
            continue;

        flags = rd_be32 (box.data) & 0xffffff;
        count = rd_be32 (box.data + 4);
        if (flags & 0x000001) p += 4;  /* data-offset */
        if (flags & 0x000004) p += 4;  /* first-sample-flags */

        if (flags & 0x000100)  /* czas zapisany przy każdej próbce */
        {
            gsize stride = 4 * (((flags & 0x100) != 0) + ((flags & 0x200) != 0) +
                                ((flags & 0x400) != 0) + ((flags & 0x800) != 0));

            if (p > box.len || (box.len - p) / stride < count)
                continue;  /* uszkodzony trun */
            for (guint32 i = 0; i < count; i++)
                fragment += rd_be32 (box.data + p + (gsize) i * stride);
        }
        else
        {
            fragment += (guint64) count * default_duration;
        }
    }

    end = (have_tfdt ? tfdt : track->end) + fragment;
    track->end = MAX (track->end, end);
}

static void
vsd_parse_moof (VsdReader    *r,
                const VsdBox *moof,
                VsdMovie     *movie)
{
    g_autofree guint8 *buf = vsd_read_alloc (r, moof->start + moof->hdr, moof->size - moof->hdr);
    gsize len = (gsize) (moof->size - moof->hdr);
    VsdMemBox box;
    gsize pos = 0;

    if (buf == NULL)
        return;

    movie->saw_moof = TRUE;
    while (vsd_mem_next_box (buf, len, &pos, &box))
    {
        if (box.type == BOX_TRAF)
            vsd_parse_traf (box.data, box.len, movie);
    }
}

static gboolean
vsd_probe_bmff (VsdReader *r,
                VsdMedia  *m)
{
    VsdMovie movie = { 0 };
    VsdBox box;
    gboolean have_moov = FALSE;
    guint64 off = 0;
    guint boxes = 0;
    double seconds = 0.0;

    m->format = "ISO BMFF/QuickTime";
    movie.tracks = g_array_new (FALSE, TRUE, sizeof (VsdTrack));

    /* Boxy najwyższego poziomu: ftyp, moov, mdat, (moof, mdat)… */
    while (vsd_read_box (r, off, r->size, &box))
    {
        if (g_cancellable_is_cancelled (r->cancellable) || ++boxes > VSD_MAX_LOOP)
            break;
        if (!vsd_fourcc_printable (box.type))
            break;  /* śmieci zamiast struktury */

        if (box.type == BOX_MOOV)
        {
            vsd_parse_moov (r, &box, &movie, m);
            have_moov = TRUE;
            if (!movie.fragmented)
                break;  /* zwykły plik: wszystko jest w moov */
        }
        else if (box.type == BOX_MOOF && have_moov && movie.fragmented)
        {
            vsd_parse_moof (r, &box, &movie);
        }
        off += box.size;
    }

    if (have_moov)
    {
        if (movie.timescale)
            seconds = (double) movie.duration / movie.timescale;

        /* W plikach fragmentowanych mvhd opisuje tylko część w moov. */
        if (movie.fragmented && movie.timescale && movie.mehd)
            seconds = MAX (seconds, (double) movie.mehd / movie.timescale);

        /* Końce ścieżek: z fragmentów albo (gdy mvhd = 0) z mdhd. */
        if (movie.fragmented || seconds <= 0.0)
        {
            for (guint i = 0; i < movie.tracks->len; i++)
            {
                VsdTrack *t = &g_array_index (movie.tracks, VsdTrack, i);
                if (t->timescale)
                    seconds = MAX (seconds, (double) t->end / t->timescale);
            }
        }
    }

    g_array_unref (movie.tracks);
    m->seconds = seconds;
    return have_moov;
}

/* ===================================================================== */
/*  Matroska / WebM: MKV, MKA, WEBM                                       */
/* ===================================================================== */

enum
{
    MKV_EBML        = 0x1A45DFA3, MKV_SEGMENT     = 0x18538067,
    MKV_INFO        = 0x1549A966, MKV_TRACKS      = 0x1654AE6B,
    MKV_CLUSTER     = 0x1F43B675, MKV_CUES        = 0x1C53BB6B,
    MKV_TIMESCALE   = 0x2AD7B1,   MKV_DURATION    = 0x4489,
    MKV_TRACKENTRY  = 0xAE,       MKV_TRACKTYPE   = 0x83,
    MKV_VIDEO       = 0xE0,       MKV_PIXELWIDTH  = 0xB0,
    MKV_PIXELHEIGHT = 0xBA,       MKV_CUEPOINT    = 0xBB,
    MKV_CUETIME     = 0xB3,       MKV_TIMESTAMP   = 0xE7,
    MKV_SIMPLEBLOCK = 0xA3,       MKV_BLOCKGROUP  = 0xA0,
    MKV_BLOCK       = 0xA1,       MKV_BLOCKDUR    = 0x9B,
};

typedef struct
{
    guint32       id;
    const guint8 *data;
    gsize         len;
} VsdEbml;

static int
vsd_vint_len (guint8 first)
{
    for (int i = 0; i < 8; i++)
    {
        if (first & (0x80 >> i))
            return i + 1;
    }
    return 0;
}

/* Nagłówek elementu EBML (ID + rozmiar) z bufora. */
static gboolean
vsd_ebml_header (const guint8 *p,
                 gsize         avail,
                 guint32      *id,
                 guint64      *size,
                 gboolean     *unknown,
                 gsize        *hdr_len)
{
    int il, sl;
    guint32 v = 0;
    guint64 s;
    gboolean ones;

    if (avail < 2)
        return FALSE;
    il = vsd_vint_len (p[0]);
    if (il == 0 || il > 4 || (gsize) il >= avail)
        return FALSE;
    for (int i = 0; i < il; i++)
        v = (v << 8) | p[i];

    sl = vsd_vint_len (p[il]);
    if (sl == 0 || (gsize) (il + sl) > avail)
        return FALSE;
    s = p[il] & (0xff >> sl);
    ones = s == (guint64) (0xff >> sl);
    for (int i = 1; i < sl; i++)
    {
        s = (s << 8) | p[il + i];
        if (p[il + i] != 0xff)
            ones = FALSE;
    }

    *id = v;
    *size = s;
    *unknown = ones;  /* same jedynki = rozmiar nieznany (strumień „na żywo”) */
    *hdr_len = (gsize) (il + sl);
    return TRUE;
}

static gboolean
vsd_ebml_next (const guint8 *buf,
               gsize         len,
               gsize        *pos,
               VsdEbml      *el)
{
    guint64 size;
    gboolean unknown;
    gsize hl, avail;

    if (*pos >= len || !vsd_ebml_header (buf + *pos, len - *pos, &el->id, &size, &unknown, &hl))
        return FALSE;
    avail = len - *pos - hl;
    if (unknown)
        size = avail;
    if (size > avail)
        return FALSE;
    el->data = buf + *pos + hl;
    el->len = (gsize) size;
    *pos += hl + (gsize) size;
    return TRUE;
}

static guint64
vsd_ebml_uint (const guint8 *p,
               gsize         len)
{
    guint64 v = 0;
    for (gsize i = 0; i < len && i < 8; i++)
        v = (v << 8) | p[i];
    return v;
}

static double
vsd_ebml_float (const VsdEbml *el)
{
    if (el->len == 4)
    {
        union { guint32 u; float f; } x = { .u = rd_be32 (el->data) };
        return x.f;
    }
    if (el->len == 8)
    {
        union { guint64 u; double d; } x = { .u = rd_be64 (el->data) };
        return x.d;
    }
    return 0.0;
}

/* Nagłówek elementu w pliku. */
static gboolean
vsd_ebml_read_header (VsdReader *r,
                      guint64    offset,
                      guint32   *id,
                      guint64   *size,
                      gboolean  *unknown,
                      gsize     *hdr_len)
{
    guint8 h[12];
    gsize n = vsd_read_some (r, offset, h, sizeof h);
    return vsd_ebml_header (h, n, id, size, unknown, hdr_len);
}

static void
vsd_mkv_parse_info (const guint8 *buf,
                    gsize         len,
                    guint64      *scale,
                    double       *duration)
{
    VsdEbml el;
    gsize pos = 0;

    while (vsd_ebml_next (buf, len, &pos, &el))
    {
        if (el.id == MKV_TIMESCALE && el.len > 0)
            *scale = vsd_ebml_uint (el.data, el.len);
        else if (el.id == MKV_DURATION)
            *duration = vsd_ebml_float (&el);
    }
}

static void
vsd_mkv_parse_tracks (const guint8 *buf,
                      gsize         len,
                      VsdMedia     *m)
{
    VsdEbml entry, el, v;
    gsize pos = 0;

    while (vsd_ebml_next (buf, len, &pos, &entry))
    {
        guint64 type = 0, width = 0, height = 0;
        gsize p2 = 0;

        if (entry.id != MKV_TRACKENTRY)
            continue;
        while (vsd_ebml_next (entry.data, entry.len, &p2, &el))
        {
            if (el.id == MKV_TRACKTYPE)
            {
                type = vsd_ebml_uint (el.data, el.len);
            }
            else if (el.id == MKV_VIDEO)
            {
                gsize p3 = 0;
                while (vsd_ebml_next (el.data, el.len, &p3, &v))
                {
                    if (v.id == MKV_PIXELWIDTH)
                        width = vsd_ebml_uint (v.data, v.len);
                    else if (v.id == MKV_PIXELHEIGHT)
                        height = vsd_ebml_uint (v.data, v.len);
                }
            }
        }
        if (type == 1 && width <= VSD_MAX_DIMENSION && height <= VSD_MAX_DIMENSION)
            vsd_media_add_video (m, (guint32) width, (guint32) height);
    }
}

static guint64
vsd_mkv_parse_cues (const guint8 *buf,
                    gsize         len)
{
    VsdEbml point, el;
    gsize pos = 0;
    guint64 last = 0;

    while (vsd_ebml_next (buf, len, &pos, &point))
    {
        gsize p2 = 0;
        if (point.id != MKV_CUEPOINT)
            continue;
        while (vsd_ebml_next (point.data, point.len, &p2, &el))
        {
            if (el.id == MKV_CUETIME)
                last = MAX (last, vsd_ebml_uint (el.data, el.len));
        }
    }
    return last;
}

/* Względny czas bloku: [numer ścieżki (vint)][int16 BE]. */
static gint64
vsd_mkv_block_time (VsdReader *r,
                    guint64    data_offset,
                    guint64    data_len)
{
    guint8 b[12];
    gsize n = vsd_read_some (r, data_offset, b, (gsize) MIN (data_len, sizeof b));
    int tl;

    if (n < 3)
        return -1;
    tl = vsd_vint_len (b[0]);
    if (tl == 0 || (gsize) tl + 2 > n)
        return -1;
    return (gint16) rd_be16 (b + tl);
}

/* Koniec ostatniego klastra: jego Timestamp + najpóźniejszy blok. */
static guint64
vsd_mkv_cluster_end (VsdReader *r,
                     guint64    start,
                     guint64    end)
{
    guint64 off = start, cluster_ts = 0;
    gint64 max_rel = 0;

    for (guint i = 0; off < end && i < 200000; i++)
    {
        guint32 id;
        guint64 size, data;
        gboolean unknown;
        gsize hl;

        if (!vsd_ebml_read_header (r, off, &id, &size, &unknown, &hl))
            break;
        data = off + hl;
        if (data > end || unknown || size > end - data)
            break;

        if (id == MKV_TIMESTAMP && size > 0 && size <= 8)
        {
            guint8 b[8];
            if (vsd_read_at (r, data, b, (gsize) size))
                cluster_ts = vsd_ebml_uint (b, (gsize) size);
        }
        else if (id == MKV_SIMPLEBLOCK)
        {
            gint64 t = vsd_mkv_block_time (r, data, size);
            max_rel = MAX (max_rel, t);
        }
        else if (id == MKV_BLOCKGROUP)
        {
            guint64 o2 = data, e2 = data + size;
            gint64 t = -1;
            guint64 dur = 0;

            while (o2 < e2)
            {
                guint32 id2;
                guint64 s2;
                gboolean u2;
                gsize h2;

                if (!vsd_ebml_read_header (r, o2, &id2, &s2, &u2, &h2) || u2 || o2 + h2 > e2 ||
                    s2 > e2 - o2 - h2)
                    break;
                if (id2 == MKV_BLOCK)
                {
                    t = vsd_mkv_block_time (r, o2 + h2, s2);
                }
                else if (id2 == MKV_BLOCKDUR && s2 > 0 && s2 <= 8)
                {
                    guint8 b[8];
                    if (vsd_read_at (r, o2 + h2, b, (gsize) s2))
                        dur = vsd_ebml_uint (b, (gsize) s2);
                }
                o2 += h2 + s2;
            }
            if (t >= 0)
                max_rel = MAX (max_rel, t + (gint64) dur);
        }
        off = data + size;
    }
    return cluster_ts + (guint64) MAX (max_rel, 0);
}

static gboolean
vsd_probe_matroska (VsdReader *r,
                    VsdMedia  *m)
{
    guint32 id;
    guint64 size, off = 0, seg_start = 0, seg_end = 0, scale = 1000000, max_cue = 0;
    guint64 last_cluster = 0, last_cluster_end = 0;
    gboolean unknown, found = FALSE, have_info = FALSE, have_tracks = FALSE, have_cluster = FALSE;
    double duration = 0.0;
    gsize hl;

    m->format = "Matroska/WebM";

    /* Najwyższy poziom: nagłówek EBML, potem Segment. */
    for (int i = 0; i < 16 && vsd_ebml_read_header (r, off, &id, &size, &unknown, &hl); i++)
    {
        if (id == MKV_SEGMENT)
        {
            seg_start = off + hl;
            seg_end = unknown ? r->size : MIN (r->size, seg_start + size);
            found = TRUE;
            break;
        }
        if (unknown)
            return FALSE;
        off += hl + size;
    }
    if (!found)
        return FALSE;

    off = seg_start;
    for (guint loops = 0; off < seg_end && loops < VSD_MAX_LOOP; loops++)
    {
        guint64 data;

        if (g_cancellable_is_cancelled (r->cancellable))
            break;
        if (!vsd_ebml_read_header (r, off, &id, &size, &unknown, &hl))
            break;
        data = off + hl;
        if (data > seg_end)
            break;
        if (unknown)
        {
            if (id == MKV_CLUSTER)
                break;  /* klastra o nieznanym rozmiarze nie da się przeskoczyć */
            size = seg_end - data;
        }
        size = MIN (size, seg_end - data);  /* ucięty plik */

        if (id == MKV_INFO || id == MKV_TRACKS || (id == MKV_CUES && duration <= 0.0))
        {
            g_autofree guint8 *buf = vsd_read_alloc (r, data, size);

            if (buf != NULL && id == MKV_INFO)
            {
                vsd_mkv_parse_info (buf, (gsize) size, &scale, &duration);
                have_info = TRUE;
            }
            else if (buf != NULL && id == MKV_TRACKS)
            {
                vsd_mkv_parse_tracks (buf, (gsize) size, m);
                have_tracks = TRUE;
            }
            else if (buf != NULL)
            {
                guint64 cue = vsd_mkv_parse_cues (buf, (gsize) size);
                max_cue = MAX (max_cue, cue);
            }
        }
        else if (id == MKV_CLUSTER)
        {
            have_cluster = TRUE;
            last_cluster = data;
            last_cluster_end = data + size;
        }

        if (have_info && have_tracks && duration > 0.0)
            break;  /* zwykły przypadek: Info i Tracks są przed klastrami */
        off = data + size;
    }

    if (scale == 0)
        scale = 1000000;
    m->seconds = duration * (double) scale / 1e9;

    /* Brak Duration (np. nagranie przerwane): koniec ostatniego klastra lub ostatni Cue. */
    if (m->seconds <= 0.0)
    {
        guint64 end_ts = max_cue;
        if (have_cluster)
        {
            guint64 cluster_end = vsd_mkv_cluster_end (r, last_cluster, last_cluster_end);
            end_ts = MAX (end_ts, cluster_end);
        }
        m->seconds = (double) end_ts * (double) scale / 1e9;
    }
    return have_info || have_tracks;
}

/* ===================================================================== */
/*  RIFF: AVI i WAV (RIFF/RF64/BW64)                                      */
/* ===================================================================== */

enum
{
    RIFF_RIFF = FOURCC ('R', 'I', 'F', 'F'), RIFF_RF64 = FOURCC ('R', 'F', '6', '4'),
    RIFF_BW64 = FOURCC ('B', 'W', '6', '4'), RIFF_AVI  = FOURCC ('A', 'V', 'I', ' '),
    RIFF_WAVE = FOURCC ('W', 'A', 'V', 'E'), RIFF_LIST = FOURCC ('L', 'I', 'S', 'T'),
    RIFF_HDRL = FOURCC ('h', 'd', 'r', 'l'), RIFF_AVIH = FOURCC ('a', 'v', 'i', 'h'),
    RIFF_STRL = FOURCC ('s', 't', 'r', 'l'), RIFF_STRH = FOURCC ('s', 't', 'r', 'h'),
    RIFF_STRF = FOURCC ('s', 't', 'r', 'f'), RIFF_ODML = FOURCC ('o', 'd', 'm', 'l'),
    RIFF_DMLH = FOURCC ('d', 'm', 'l', 'h'), RIFF_VIDS = FOURCC ('v', 'i', 'd', 's'),
    RIFF_AUDS = FOURCC ('a', 'u', 'd', 's'), RIFF_FMT  = FOURCC ('f', 'm', 't', ' '),
    RIFF_FACT = FOURCC ('f', 'a', 'c', 't'), RIFF_DATA = FOURCC ('d', 'a', 't', 'a'),
    RIFF_DS64 = FOURCC ('d', 's', '6', '4'),
};

/* Kolejny podrozdział RIFF z bufora. ID porównujemy jako big-endian FOURCC. */
static gboolean
vsd_riff_next (const guint8  *buf,
               gsize          len,
               gsize         *pos,
               guint32       *id,
               const guint8 **data,
               gsize         *dlen)
{
    guint32 size;

    if (*pos > len || len - *pos < 8)
        return FALSE;
    *id = rd_be32 (buf + *pos);
    size = rd_le32 (buf + *pos + 4);
    if (size > len - *pos - 8)
        size = (guint32) (len - *pos - 8);  /* ucięty */
    *data = buf + *pos + 8;
    *dlen = size;
    *pos += 8 + (gsize) size + (size & 1);
    return TRUE;
}

typedef struct
{
    guint32 us_per_frame, total_frames, width, height, dmlh_frames;
    gboolean have_video;
    guint32 v_scale, v_rate, v_length, v_width, v_height;
    double audio_seconds;
} VsdAvi;

static void
vsd_avi_parse_strl (const guint8 *buf,
                    gsize         len,
                    VsdAvi       *avi)
{
    const guint8 *data;
    gsize dlen, pos = 0;
    guint32 id, type = 0, scale = 0, rate = 0, length = 0;
    gboolean first_video = FALSE;

    while (vsd_riff_next (buf, len, &pos, &id, &data, &dlen))
    {
        if (id == RIFF_STRH && dlen >= 36)
        {
            type = rd_be32 (data);
            scale = rd_le32 (data + 20);
            rate = rd_le32 (data + 24);
            length = rd_le32 (data + 32);
            if (type == RIFF_VIDS && !avi->have_video)
            {
                avi->have_video = first_video = TRUE;
                avi->v_scale = scale;
                avi->v_rate = rate;
                avi->v_length = length;
            }
            else if (type == RIFF_AUDS && rate > 0)
            {
                avi->audio_seconds = MAX (avi->audio_seconds, (double) length * scale / rate);
            }
        }
        else if (id == RIFF_STRF && first_video && dlen >= 12)
        {
            /* BITMAPINFOHEADER: biWidth, biHeight (ujemna = obraz od góry) */
            gint32 w = (gint32) rd_le32 (data + 4), h = (gint32) rd_le32 (data + 8);
            avi->v_width = (guint32) ABS (w);
            avi->v_height = (guint32) ABS (h);
        }
    }
}

static void
vsd_avi_parse_list (const guint8 *buf,
                    gsize         len,
                    VsdAvi       *avi,
                    int           depth)
{
    const guint8 *data;
    gsize dlen, pos = 0;
    guint32 id;

    while (depth < 4 && vsd_riff_next (buf, len, &pos, &id, &data, &dlen))
    {
        if (id == RIFF_AVIH && dlen >= 40)
        {
            avi->us_per_frame = rd_le32 (data);
            avi->total_frames = rd_le32 (data + 16);
            avi->width = rd_le32 (data + 32);
            avi->height = rd_le32 (data + 36);
        }
        else if (id == RIFF_DMLH && dlen >= 4)
        {
            avi->dmlh_frames = rd_le32 (data);  /* OpenDML: wszystkie klatki (> 1 GiB) */
        }
        else if (id == RIFF_LIST && dlen >= 4)
        {
            if (rd_be32 (data) == RIFF_STRL)
                vsd_avi_parse_strl (data + 4, dlen - 4, avi);
            else
                vsd_avi_parse_list (data + 4, dlen - 4, avi, depth + 1);
        }
    }
}

static gboolean
vsd_probe_avi (VsdReader *r,
               VsdMedia  *m)
{
    VsdAvi avi = { 0 };
    guint64 off = 12;
    gboolean have_hdrl = FALSE;

    m->format = "AVI";
    for (int i = 0; i < 64 && off + 12 <= r->size; i++)
    {
        guint8 h[12];
        guint32 size;

        if (!vsd_read_at (r, off, h, sizeof h))
            break;
        size = rd_le32 (h + 4);
        if (rd_be32 (h) == RIFF_LIST && rd_be32 (h + 8) == RIFF_HDRL && size >= 4)
        {
            g_autofree guint8 *buf = vsd_read_alloc (r, off + 12, MIN ((guint64) size - 4, r->size - off - 12));
            if (buf != NULL)
            {
                vsd_avi_parse_list (buf, (gsize) MIN ((guint64) size - 4, r->size - off - 12), &avi, 0);
                have_hdrl = TRUE;
            }
            break;
        }
        off += 8 + (guint64) size + (size & 1);
    }
    if (!have_hdrl)
        return FALSE;

    if (avi.have_video && avi.v_rate > 0 && avi.v_scale > 0)
    {
        guint32 frames = MAX (avi.v_length, avi.dmlh_frames);
        m->seconds = (double) frames * avi.v_scale / avi.v_rate;
    }
    if (m->seconds <= 0.0)
        m->seconds = avi.audio_seconds;
    if (m->seconds <= 0.0)
        m->seconds = (double) MAX (avi.total_frames, avi.dmlh_frames) * avi.us_per_frame / 1e6;

    if (avi.have_video)
    {
        if (avi.v_width && avi.v_height)
            vsd_media_add_video (m, avi.v_width, avi.v_height);
        else
            vsd_media_add_video (m, avi.width, avi.height);
    }
    return TRUE;
}

static gboolean
vsd_probe_wav (VsdReader    *r,
               const guint8 *head,
               VsdMedia     *m)
{
    guint64 off = 12, data_size = 0, ds64_data = 0, data_offset = 0, end = r->size;
    guint32 riff_size = rd_le32 (head + 4), sample_rate = 0, avg_bytes = 0, fact = 0;
    guint16 tag = 0, block_align = 0;
    gboolean rf64 = rd_be32 (head) != RIFF_RIFF, have_fmt = FALSE, have_data = FALSE, have_fact = FALSE;

    m->format = "WAV";
    if (!rf64 && riff_size >= 4 && (guint64) riff_size + 8 < r->size)
        end = (guint64) riff_size + 8;

    for (int i = 0; i < 256 && off + 8 <= end; i++)
    {
        guint8 h[8], p[40];
        guint32 id, size;
        guint64 chunk;

        if (!vsd_read_at (r, off, h, sizeof h))
            break;
        id = rd_be32 (h);
        size = rd_le32 (h + 4);
        chunk = size;

        if (id == RIFF_DS64 && size >= 24 && vsd_read_at (r, off + 8, p, 24))
        {
            ds64_data = rd_le64 (p + 8);
        }
        else if (id == RIFF_FMT && size >= 16 && vsd_read_at (r, off + 8, p, MIN (size, sizeof p)))
        {
            tag = rd_le16 (p);
            sample_rate = rd_le32 (p + 4);
            avg_bytes = rd_le32 (p + 8);
            block_align = rd_le16 (p + 12);
            if (tag == 0xFFFE && size >= 40)  /* WAVE_FORMAT_EXTENSIBLE: kod w SubFormat */
                tag = rd_le16 (p + 24);
            have_fmt = TRUE;
        }
        else if (id == RIFF_FACT && size >= 4 && vsd_read_at (r, off + 8, p, 4))
        {
            fact = rd_le32 (p);
            have_fact = TRUE;
        }
        else if (id == RIFF_DATA)
        {
            data_offset = off + 8;
            data_size = size;
            if (rf64 && size == G_MAXUINT32)
                data_size = ds64_data;
            if (data_size == 0 || data_size > r->size - data_offset)
                data_size = r->size - data_offset;  /* nagrywany strumieniowo / ucięty */
            chunk = data_size;
            have_data = TRUE;
            if (have_fmt)
                break;
        }
        off += 8 + chunk + (chunk & 1);
    }

    if (!have_fmt || !have_data)
        return have_fmt;

    /* PCM, float, A-law, µ-law: stała liczba bajtów na próbkę. */
    if ((tag == 1 || tag == 3 || tag == 6 || tag == 7) && block_align > 0 && sample_rate > 0)
        m->seconds = (double) (data_size / block_align) / sample_rate;
    else if (have_fact && fact > 0 && sample_rate > 0)
        m->seconds = (double) fact / sample_rate;
    else if (avg_bytes > 0)
        m->seconds = (double) data_size / avg_bytes;
    return TRUE;
}

/* ===================================================================== */
/*  Ogg: Vorbis, Opus, FLAC, Speex, Theora                                */
/* ===================================================================== */

enum { OGG_UNKNOWN, OGG_VORBIS, OGG_OPUS, OGG_FLAC, OGG_SPEEX, OGG_THEORA };

typedef struct
{
    guint32  serial;
    int      codec;
    guint32  rate;          /* jednostka granule: próbki/s (Opus: zawsze 48 kHz) */
    guint32  preskip;
    guint32  frn, frd;      /* Theora: klatki/s = frn/frd */
    guint8   shift;         /* Theora: KFGSHIFT */
    gboolean theora_old;    /* < 3.2.1: numeracja klatek od 0 */
    guint64  granule;
    gboolean have_granule;
} VsdOggStream;

typedef struct
{
    guint8        type;
    guint64       granule;
    guint32       serial;
    const guint8 *body;
    gsize         body_len;
    gsize         page_len;
} VsdOggPage;

static guint32 vsd_ogg_crc_table[256];

static void
vsd_ogg_crc_init (void)
{
    static gsize done = 0;

    if (g_once_init_enter (&done))
    {
        for (guint32 i = 0; i < 256; i++)
        {
            guint32 c = i << 24;
            for (int k = 0; k < 8; k++)
                c = (c & 0x80000000u) ? (c << 1) ^ 0x04c11db7u : c << 1;
            vsd_ogg_crc_table[i] = c;
        }
        g_once_init_leave (&done, 1);
    }
}

/* CRC strony z polem sumy (bajty 22–25) liczonym jako zera. */
static guint32
vsd_ogg_crc (const guint8 *p,
             gsize         len)
{
    guint32 crc = 0;

    for (gsize i = 0; i < len; i++)
    {
        guint8 b = (i >= 22 && i < 26) ? 0 : p[i];
        crc = (crc << 8) ^ vsd_ogg_crc_table[((crc >> 24) & 0xff) ^ b];
    }
    return crc;
}

static gboolean
vsd_ogg_page (const guint8 *buf,
              gsize         len,
              gsize         pos,
              gboolean      check_crc,
              VsdOggPage   *pg)
{
    gsize nseg, body = 0, total;

    if (pos > len || len - pos < 27 || memcmp (buf + pos, "OggS", 4) != 0 || buf[pos + 4] != 0)
        return FALSE;
    nseg = buf[pos + 26];
    if (len - pos < 27 + nseg)
        return FALSE;
    for (gsize i = 0; i < nseg; i++)
        body += buf[pos + 27 + i];
    total = 27 + nseg + body;
    if (len - pos < total)
        return FALSE;
    if (check_crc && vsd_ogg_crc (buf + pos, total) != rd_le32 (buf + pos + 22))
        return FALSE;

    pg->type = buf[pos + 5];
    pg->granule = rd_le64 (buf + pos + 6);
    pg->serial = rd_le32 (buf + pos + 14);
    pg->body = buf + pos + 27 + nseg;
    pg->body_len = body;
    pg->page_len = total;
    return TRUE;
}

static void
vsd_ogg_identify (VsdOggStream *s,
                  const guint8 *b,
                  gsize         n,
                  VsdMedia     *m)
{
    if (n >= 16 && b[0] == 0x01 && memcmp (b + 1, "vorbis", 6) == 0)
    {
        s->codec = OGG_VORBIS;
        s->rate = rd_le32 (b + 12);
    }
    else if (n >= 19 && memcmp (b, "OpusHead", 8) == 0)
    {
        s->codec = OGG_OPUS;
        s->rate = 48000;
        s->preskip = rd_le16 (b + 10);
    }
    else if (n >= 13 + 4 + 18 && b[0] == 0x7f && memcmp (b + 1, "FLAC", 4) == 0)
    {
        const guint8 *si = b + 13 + 4;  /* STREAMINFO po nagłówku mapowania */
        s->codec = OGG_FLAC;
        s->rate = ((guint32) si[10] << 12) | ((guint32) si[11] << 4) | (si[12] >> 4);
    }
    else if (n >= 40 && memcmp (b, "Speex   ", 8) == 0)
    {
        s->codec = OGG_SPEEX;
        s->rate = rd_le32 (b + 36);
    }
    else if (n >= 42 && b[0] == 0x80 && memcmp (b + 1, "theora", 6) == 0)
    {
        guint32 version = ((guint32) b[7] << 16) | ((guint32) b[8] << 8) | b[9];

        s->codec = OGG_THEORA;
        s->theora_old = version < 0x030201;
        s->frn = rd_be32 (b + 22);
        s->frd = rd_be32 (b + 26);
        s->shift = (guint8) (((b[40] & 0x03) << 3) | (b[41] >> 5));
        vsd_media_add_video (m, rd_be24 (b + 14), rd_be24 (b + 17));  /* PICW × PICH */
    }
}

static double
vsd_ogg_stream_seconds (const VsdOggStream *s)
{
    if (!s->have_granule || s->granule == G_MAXUINT64)
        return 0.0;

    switch (s->codec)
    {
        case OGG_VORBIS:
        case OGG_FLAC:
        case OGG_SPEEX:
            return s->rate ? (double) s->granule / s->rate : 0.0;
        case OGG_OPUS:
            return s->granule > s->preskip ? (double) (s->granule - s->preskip) / 48000.0 : 0.0;
        case OGG_THEORA:
        {
            guint64 mask = s->shift < 64 ? (((guint64) 1 << s->shift) - 1) : G_MAXUINT64;
            guint64 frames = (s->granule >> s->shift) + (s->granule & mask) + (s->theora_old ? 1 : 0);
            return s->frn ? (double) frames * s->frd / s->frn : 0.0;
        }
        default:
            return 0.0;
    }
}

/* Ostatnie granule każdego strumienia z końcówki pliku. */
static gboolean
vsd_ogg_scan_tail (VsdReader    *r,
                   gsize         tail,
                   VsdOggStream *streams,
                   int           count)
{
    guint64 start = r->size > tail ? r->size - tail : 0;
    gsize len = (gsize) (r->size - start);
    g_autofree guint8 *buf = vsd_read_alloc (r, start, len);
    gboolean any = FALSE;
    gsize pos = 0;

    if (buf == NULL)
        return FALSE;

    while (pos + 27 <= len)
    {
        guint8 *hit = memmem (buf + pos, len - pos, "OggS", 4);
        VsdOggPage pg;

        if (hit == NULL)
            break;
        pos = (gsize) (hit - buf);
        if (!vsd_ogg_page (buf, len, pos, TRUE, &pg))
        {
            pos++;
            continue;
        }
        for (int i = 0; i < count; i++)
        {
            if (streams[i].serial == pg.serial && pg.granule != G_MAXUINT64)
            {
                streams[i].granule = pg.granule;
                streams[i].have_granule = any = TRUE;
            }
        }
        pos += pg.page_len;
    }
    return any;
}

static gboolean
vsd_probe_ogg (VsdReader *r,
               VsdMedia  *m)
{
    VsdOggStream streams[16] = { { 0 } };
    int count = 0;
    gsize len = (gsize) MIN (r->size, (guint64) 256 * 1024), pos = 0;
    g_autofree guint8 *head = vsd_read_alloc (r, 0, len);
    VsdOggPage pg;

    m->format = "Ogg";
    if (head == NULL)
        return FALSE;
    vsd_ogg_crc_init ();

    /* Strony BOS (początek strumienia) są na początku pliku, przed danymi. */
    while (count < (int) G_N_ELEMENTS (streams) && vsd_ogg_page (head, len, pos, FALSE, &pg))
    {
        if (!(pg.type & 0x02))
            break;
        streams[count].serial = pg.serial;
        vsd_ogg_identify (&streams[count], pg.body, pg.body_len, m);
        count++;
        pos += pg.page_len;
    }
    if (count == 0)
        return FALSE;

    if (!vsd_ogg_scan_tail (r, 128 * 1024, streams, count))
        vsd_ogg_scan_tail (r, 1024 * 1024, streams, count);

    for (int i = 0; i < count; i++)
        m->seconds = MAX (m->seconds, vsd_ogg_stream_seconds (&streams[i]));
    return TRUE;
}

/* ===================================================================== */
/*  FLAC (natywny)                                                        */
/* ===================================================================== */

static gboolean
vsd_probe_flac (VsdReader *r,
                guint64    start,
                VsdMedia  *m)
{
    guint8 p[4 + 4 + 18];
    guint32 rate;
    guint64 samples;

    m->format = "FLAC";
    /* "fLaC", nagłówek bloku (typ 0 = STREAMINFO), STREAMINFO */
    if (!vsd_read_at (r, start, p, sizeof p) || (p[4] & 0x7f) != 0 || rd_be24 (p + 5) < 18)
        return FALSE;
    rate = ((guint32) p[18] << 12) | ((guint32) p[19] << 4) | (p[20] >> 4);
    samples = ((guint64) (p[21] & 0x0f) << 32) | rd_be32 (p + 22);
    if (rate > 0 && samples > 0)
        m->seconds = (double) samples / rate;
    return TRUE;
}

/* ===================================================================== */
/*  ASF: WMA, WMV                                                         */
/* ===================================================================== */

static const guint8 ASF_HEADER[16] = {
    0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C };
static const guint8 ASF_FILE_PROPERTIES[16] = {
    0xA1, 0xDC, 0xAB, 0x8C, 0x47, 0xA9, 0xCF, 0x11, 0x8E, 0xE4, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65 };
static const guint8 ASF_STREAM_PROPERTIES[16] = {
    0x91, 0x07, 0xDC, 0xB7, 0xB7, 0xA9, 0xCF, 0x11, 0x8E, 0xE6, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65 };
static const guint8 ASF_VIDEO_MEDIA[16] = {
    0xC0, 0xEF, 0x19, 0xBC, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B };

static gboolean
vsd_probe_asf (VsdReader *r,
               VsdMedia  *m)
{
    guint8 h[30];
    guint64 off = 30, end;
    gboolean have_props = FALSE;

    m->format = "ASF";
    if (!vsd_read_at (r, 0, h, sizeof h))
        return FALSE;
    end = MIN (rd_le64 (h + 16), r->size);

    for (guint i = 0; i < 1024 && off + 24 <= end; i++)
    {
        guint8 o[24], p[68];
        guint64 size;

        if (!vsd_read_at (r, off, o, sizeof o))
            break;
        size = rd_le64 (o + 16);
        if (size < 24 || size > end - off)
            break;

        if (memcmp (o, ASF_FILE_PROPERTIES, 16) == 0 && size >= 24 + 80 &&
            vsd_read_at (r, off + 24, p, 68))
        {
            guint64 play = rd_le64 (p + 40);    /* 100 ns */
            guint64 preroll = rd_le64 (p + 56); /* ms */

            if (!(rd_le32 (p + 64) & 0x01))     /* flaga „broadcast”: czasy nieważne */
            {
                double s = (double) play / 1e7 - (double) preroll / 1000.0;
                m->seconds = s > 0.0 ? s : (double) play / 1e7;
            }
            have_props = TRUE;
        }
        else if (memcmp (o, ASF_STREAM_PROPERTIES, 16) == 0 && size >= 24 + 62 &&
                 vsd_read_at (r, off + 24, p, 62) && memcmp (p, ASF_VIDEO_MEDIA, 16) == 0)
        {
            vsd_media_add_video (m, rd_le32 (p + 54), rd_le32 (p + 58));  /* Encoded Image W × H */
        }
        off += size;
    }
    return have_props;
}

/* ===================================================================== */
/*  MPEG audio (MP3/MP2) i AAC ADTS                                       */
/* ===================================================================== */

typedef struct
{
    guint32 sample_rate, bitrate, samples, frame_len, xing_offset;
    guint8  version, layer;
} VsdMpa;

static const guint16 vsd_mpa_bitrates[2][3][16] = {
    { { 0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0 },
      { 0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0 },
      { 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 } },
    { { 0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0 },
      { 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 },
      { 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 } },
};

static gboolean
vsd_mpa_parse (const guint8 *p,
               VsdMpa       *f)
{
    static const guint32 rates[3] = { 44100, 48000, 32000 };
    guint32 h = rd_be32 (p), version, layer, bri, sri, pad, mode;
    gboolean lsf;

    if ((h & 0xFFE00000u) != 0xFFE00000u)
        return FALSE;
    version = (h >> 19) & 3;  /* 0: MPEG-2.5, 2: MPEG-2, 3: MPEG-1 */
    layer = 4 - ((h >> 17) & 3);
    bri = (h >> 12) & 15;
    sri = (h >> 10) & 3;
    pad = (h >> 9) & 1;
    mode = (h >> 6) & 3;
    if (version == 1 || layer == 4 || bri == 0 || bri == 15 || sri == 3)
        return FALSE;

    lsf = version != 3;
    f->version = (guint8) version;
    f->layer = (guint8) layer;
    f->bitrate = vsd_mpa_bitrates[lsf][layer - 1][bri] * 1000u;
    f->sample_rate = rates[sri] >> (version == 3 ? 0 : version == 2 ? 1 : 2);
    f->samples = layer == 1 ? 384 : (layer == 2 || !lsf) ? 1152 : 576;
    f->frame_len = layer == 1 ? (12 * f->bitrate / f->sample_rate + pad) * 4
                              : f->samples / 8 * f->bitrate / f->sample_rate + pad;
    f->xing_offset = 4 + (lsf ? (mode == 3 ? 9 : 17) : (mode == 3 ? 17 : 32));
    return f->frame_len >= 24;
}

static gboolean
vsd_adts_parse (const guint8 *p,
                guint32      *rate,
                guint32      *frame_len,
                guint32      *samples)
{
    static const guint32 rates[13] = { 96000, 88200, 64000, 48000, 44100, 32000,
                                       24000, 22050, 16000, 12000, 11025, 8000, 7350 };
    guint32 sfi;

    if (p[0] != 0xFF || (p[1] & 0xF6) != 0xF0)
        return FALSE;
    sfi = (p[2] >> 2) & 0x0F;
    if (sfi >= 13)
        return FALSE;
    *rate = rates[sfi];
    *frame_len = ((guint32) (p[3] & 0x03) << 11) | ((guint32) p[4] << 3) | (p[5] >> 5);
    *samples = 1024 * ((p[6] & 0x03) + 1u);
    return *frame_len >= 7;
}

/* Bajty na końcu pliku zajęte przez tagi (ID3v1). */
static guint64
vsd_audio_end (VsdReader *r)
{
    guint8 t[3];
    if (r->size > 128 && vsd_read_at (r, r->size - 128, t, 3) && memcmp (t, "TAG", 3) == 0)
        return r->size - 128;
    return r->size;
}

static gboolean
vsd_probe_mpeg_audio (VsdReader *r,
                      guint64    start,
                      VsdMedia  *m)
{
    gsize len = (gsize) MIN (r->size - MIN (start, r->size), (guint64) 1024 * 1024);
    g_autofree guint8 *buf = vsd_read_alloc (r, start, len);
    guint64 audio_end = vsd_audio_end (r);

    if (buf == NULL)
        return FALSE;

    /* Pierwsza ramka potwierdzona przez dwie kolejne (mniej fałszywych trafień). */
    for (gsize pos = 0; pos + 10 <= len && pos < 128 * 1024; pos++)
    {
        guint32 rate, flen, spf;
        VsdMpa f, g, h;

        if (buf[pos] != 0xFF)
            continue;

        if (vsd_adts_parse (buf + pos, &rate, &flen, &spf))
        {
            guint32 r2, l2, s2;
            guint64 frames = 0, bytes = 0, samples = 0;
            gsize p = pos;

            if (p + flen + 7 <= len && !(vsd_adts_parse (buf + p + flen, &r2, &l2, &s2) && r2 == rate))
                continue;

            m->format = "AAC ADTS";
            while (p + 7 <= len && vsd_adts_parse (buf + p, &r2, &l2, &s2) && r2 == rate && p + l2 <= len)
            {
                frames++;
                bytes += l2;
                samples += s2;
                p += l2;
            }
            if (frames == 0 || bytes == 0)
                return FALSE;
            if (start + p >= audio_end || start + len >= r->size)
                m->seconds = (double) samples / rate;  /* cały plik przeliczony */
            else                                       /* szacunek ze średniej ramki */
                m->seconds = (double) (audio_end - start - pos) * ((double) samples / (double) bytes) / rate;
            return TRUE;
        }

        if (vsd_mpa_parse (buf + pos, &f) &&
            (pos + f.frame_len + 4 > len ||
             (vsd_mpa_parse (buf + pos + f.frame_len, &g) && g.sample_rate == f.sample_rate &&
              g.layer == f.layer && g.version == f.version &&
              (pos + f.frame_len + g.frame_len + 4 > len ||
               (vsd_mpa_parse (buf + pos + f.frame_len + g.frame_len, &h) && h.sample_rate == f.sample_rate)))))
        {
            const guint8 *x = buf + pos + f.xing_offset;
            const guint8 *v = buf + pos + 36;

            m->format = "MPEG audio";
            /* Xing/Info (LAME) lub VBRI (Fraunhofer): dokładna liczba ramek. */
            if (pos + f.xing_offset + 12 <= len && (memcmp (x, "Xing", 4) == 0 || memcmp (x, "Info", 4) == 0) &&
                (rd_be32 (x + 4) & 0x01))
            {
                m->seconds = (double) rd_be32 (x + 8) * f.samples / f.sample_rate;
            }
            else if (pos + 36 + 18 <= len && memcmp (v, "VBRI", 4) == 0)
            {
                m->seconds = (double) rd_be32 (v + 14) * f.samples / f.sample_rate;
            }
            else if (f.bitrate > 0 && audio_end > start + pos)
            {
                m->seconds = (double) (audio_end - start - pos) * 8.0 / f.bitrate;  /* CBR */
            }
            return TRUE;
        }
    }
    return FALSE;
}

/* Pomija tagi ID3v2 na początku pliku (MP3, AAC, czasem FLAC). */
static guint64
vsd_skip_id3v2 (VsdReader *r)
{
    guint64 off = 0;
    guint8 h[10];

    for (int i = 0; i < 4 && vsd_read_at (r, off, h, sizeof h) && memcmp (h, "ID3", 3) == 0; i++)
    {
        guint32 size = ((guint32) (h[6] & 0x7f) << 21) | ((guint32) (h[7] & 0x7f) << 14) |
                       ((guint32) (h[8] & 0x7f) << 7) | (h[9] & 0x7f);
        off += 10 + (guint64) size + ((h[5] & 0x10) ? 10 : 0);
    }
    return off;
}

/* ===================================================================== */
/*  Rozpoznanie formatu po zawartości                                     */
/* ===================================================================== */

/* Uruchamiane w wątku roboczym. */
static gboolean
vsd_probe (GFile        *location,
           guint         hints,
           GCancellable *cancellable,
           VsdMedia     *m)
{
    g_autoptr (GFileInputStream) stream = NULL;
    g_autoptr (GFileInfo) info = NULL;
    VsdReader r = { 0 };
    guint8 head[64];
    gsize n;
    guint64 start;

    memset (m, 0, sizeof *m);
    stream = g_file_read (location, cancellable, NULL);
    if (stream == NULL || !g_seekable_can_seek (G_SEEKABLE (stream)))
        return FALSE;

    r.in = G_INPUT_STREAM (stream);
    r.cancellable = cancellable;
    info = g_file_input_stream_query_info (stream, G_FILE_ATTRIBUTE_STANDARD_SIZE, cancellable, NULL);
    if (info != NULL && g_file_info_has_attribute (info, G_FILE_ATTRIBUTE_STANDARD_SIZE))
        r.size = (guint64) g_file_info_get_size (info);
    else if (g_seekable_seek (G_SEEKABLE (stream), 0, G_SEEK_END, cancellable, NULL))
        r.size = (guint64) g_seekable_tell (G_SEEKABLE (stream));

    n = vsd_read_some (&r, 0, head, sizeof head);
    if (n < 16)
        return FALSE;

    if (vsd_bmff_known_box (rd_be32 (head + 4)))
        return vsd_probe_bmff (&r, m);
    if (rd_be32 (head) == MKV_EBML)
        return vsd_probe_matroska (&r, m);
    if ((rd_be32 (head) == RIFF_RIFF || rd_be32 (head) == RIFF_RF64 || rd_be32 (head) == RIFF_BW64) &&
        rd_be32 (head + 8) == RIFF_WAVE)
        return vsd_probe_wav (&r, head, m);
    if (rd_be32 (head) == RIFF_RIFF && rd_be32 (head + 8) == RIFF_AVI)
        return vsd_probe_avi (&r, m);
    if (memcmp (head, "OggS", 4) == 0)
        return vsd_probe_ogg (&r, m);
    if (memcmp (head, ASF_HEADER, 16) == 0)
        return vsd_probe_asf (&r, m);

    start = vsd_skip_id3v2 (&r);
    n = vsd_read_some (&r, start, head, 4);
    if (n == 4 && memcmp (head, "fLaC", 4) == 0)
        return vsd_probe_flac (&r, start, m);
    if ((n >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) || start > 0 || (hints & VSD_HINT_MPEG_AUDIO))
        return vsd_probe_mpeg_audio (&r, start, m);
    return FALSE;
}

/* ===================================================================== */
/*  Formatowanie (stała szerokość, bo Nautilus sortuje przez strcmp)      */
/* ===================================================================== */

/* "    3:25", "   42:07", " 1:02:05" — dopełnione spacjami do 8 znaków. */
static char *
vsd_format_duration (double seconds)
{
    char tmp[32];
    guint64 s;

    if (seconds <= 0.0 || seconds > VSD_MAX_SECONDS)
        return g_strdup ("");
    s = (guint64) (seconds + 0.5);
    if (s >= 3600)
        g_snprintf (tmp, sizeof tmp, "%" G_GUINT64_FORMAT ":%02u:%02u",
                    s / 3600, (guint) (s / 60 % 60), (guint) (s % 60));
    else
        g_snprintf (tmp, sizeof tmp, "%u:%02u", (guint) (s / 60), (guint) (s % 60));
    return g_strdup_printf ("%8s", tmp);
}

/* "  720", " 1920" — dopełnione spacjami do 5 znaków. */
static char *
vsd_format_pixels (guint32 px)
{
    return px ? g_strdup_printf ("%5u", px) : g_strdup ("");
}

/* ===================================================================== */
/*  Rozszerzenie Nautilusa                                                */
/* ===================================================================== */

typedef struct
{
    GObject parent_instance;
} VideoSizeDurationProvider;

typedef struct
{
    GObjectClass parent_class;
} VideoSizeDurationProviderClass;

/* Uchwyt jednej operacji; Nautilus widzi go jako NautilusOperationHandle*. */
typedef struct
{
    GClosure             *update_complete;
    NautilusInfoProvider *provider;
    NautilusFileInfo     *file;
    GCancellable         *cancellable;
} VsdRequest;

typedef struct
{
    GFile *location;
    guint  hints;
} VsdJob;

static void vsd_column_provider_iface_init (NautilusColumnProviderInterface *iface);
static void vsd_info_provider_iface_init (NautilusInfoProviderInterface *iface);

G_DEFINE_DYNAMIC_TYPE_EXTENDED (VideoSizeDurationProvider, video_size_duration_provider, G_TYPE_OBJECT, 0,
                                G_IMPLEMENT_INTERFACE_DYNAMIC (NAUTILUS_TYPE_COLUMN_PROVIDER,
                                                               vsd_column_provider_iface_init)
                                G_IMPLEMENT_INTERFACE_DYNAMIC (NAUTILUS_TYPE_INFO_PROVIDER,
                                                               vsd_info_provider_iface_init))

static void video_size_duration_provider_init (VideoSizeDurationProvider *self) { (void) self; }
static void video_size_duration_provider_class_init (VideoSizeDurationProviderClass *klass) { (void) klass; }
static void video_size_duration_provider_class_finalize (VideoSizeDurationProviderClass *klass) { (void) klass; }

static NautilusColumn *
vsd_column_new (const char *attribute,
                const char *label,
                const char *description)
{
    NautilusColumn *column = nautilus_column_new (attribute, attribute, label, description);

    g_object_set (column,
                  "xalign", 1.0,
                  "default-sort-order", 1, /* GTK_SORT_DESCENDING: największe na górze */
                  NULL);
    return column;
}

static GList *
vsd_get_columns (NautilusColumnProvider *provider)
{
    const VsdStrings *s = vsd_pick_strings ();
    GList *columns = NULL;

    (void) provider;
    columns = g_list_append (columns, vsd_column_new (VSD_ATTR_DURATION, s->duration_label, s->duration_desc));
    columns = g_list_append (columns, vsd_column_new (VSD_ATTR_WIDTH, s->width_label, s->width_desc));
    columns = g_list_append (columns, vsd_column_new (VSD_ATTR_HEIGHT, s->height_label, s->height_desc));
    return columns;
}

static void
vsd_column_provider_iface_init (NautilusColumnProviderInterface *iface)
{
    iface->get_columns = vsd_get_columns;
}

static const char *const vsd_suffixes[] = {
    ".mp4", ".m4v", ".m4a", ".m4b", ".mov", ".3gp", ".3g2",
    ".mkv", ".mka", ".webm", ".avi", ".wav", ".ogg", ".oga", ".ogv", ".opus", ".spx",
    ".flac", ".wma", ".wmv", ".asf", ".mp3", ".mp2", ".aac", NULL
};

/* Czy warto otwierać plik; zwraca też podpowiedzi dla parsera. */
static gboolean
vsd_is_candidate (NautilusFileInfo *file,
                  guint            *hints)
{
    g_autofree char *mime = NULL;
    g_autofree char *name = NULL;
    g_autofree char *lower = NULL;
    gboolean known_suffix = FALSE;

    *hints = 0;
    /* Tylko zwykłe pliki: czytanie np. kolejki FIFO zablokowałoby wątek. */
    if (nautilus_file_info_get_file_type (file) != G_FILE_TYPE_REGULAR)
        return FALSE;

    name = nautilus_file_info_get_name (file);
    lower = name ? g_utf8_strdown (name, -1) : g_strdup ("");
    for (const char *const *suffix = vsd_suffixes; *suffix != NULL; suffix++)
    {
        if (g_str_has_suffix (lower, *suffix))
            known_suffix = TRUE;
    }
    if (g_str_has_suffix (lower, ".mp3") || g_str_has_suffix (lower, ".mp2") || g_str_has_suffix (lower, ".aac"))
        *hints |= VSD_HINT_MPEG_AUDIO;

    mime = nautilus_file_info_get_mime_type (file);
    if (mime != NULL && (g_str_equal (mime, "audio/mpeg") || g_str_has_prefix (mime, "audio/aac") ||
                         g_str_has_prefix (mime, "audio/x-aac") || g_str_equal (mime, "audio/x-hx-aac-adts")))
        *hints |= VSD_HINT_MPEG_AUDIO;

    /* Wszystkie typy audio/... i video/... sprawdzamy po zawartości; nieobsługiwane dostaną pustą komórkę. */
    return known_suffix ||
           (mime != NULL && (g_str_has_prefix (mime, "video/") || g_str_has_prefix (mime, "audio/") ||
                             g_str_equal (mime, "application/ogg") ||
                             g_str_equal (mime, "application/mp4") ||
                             g_str_equal (mime, "application/x-matroska") ||  /* MKV bez rozszerzenia */
                             g_str_equal (mime, "application/vnd.ms-asf")));
}

static void
vsd_set_attributes (NautilusFileInfo *file,
                    const VsdMedia   *m)
{
    g_autofree char *duration = vsd_format_duration (m ? m->seconds : 0.0);
    g_autofree char *width = vsd_format_pixels (m ? m->width : 0);
    g_autofree char *height = vsd_format_pixels (m ? m->height : 0);

    nautilus_file_info_add_string_attribute (file, VSD_ATTR_DURATION, duration);
    nautilus_file_info_add_string_attribute (file, VSD_ATTR_WIDTH, width);
    nautilus_file_info_add_string_attribute (file, VSD_ATTR_HEIGHT, height);
}

static void
vsd_request_free (VsdRequest *request)
{
    g_closure_unref (request->update_complete);
    g_object_unref (request->provider);
    g_object_unref (request->file);
    g_object_unref (request->cancellable);
    g_free (request);
}

static void
vsd_job_free (VsdJob *job)
{
    g_object_unref (job->location);
    g_free (job);
}

static void
vsd_probe_thread (GTask        *task,
                  gpointer      source_object,
                  gpointer      task_data,
                  GCancellable *cancellable)
{
    VsdJob *job = task_data;
    VsdMedia *media = g_new0 (VsdMedia, 1);

    (void) source_object;
    if (!vsd_probe (job->location, job->hints, cancellable, media))
        memset (media, 0, sizeof *media);
    g_task_return_pointer (task, media, g_free);
}

/* Wraca w głównym wątku (tam, gdzie powstało zadanie). */
static void
vsd_probe_done (GObject      *source_object,
                GAsyncResult *result,
                gpointer      user_data)
{
    VsdRequest *request = user_data;
    g_autofree VsdMedia *media = g_task_propagate_pointer (G_TASK (result), NULL);
    gboolean cancelled = g_cancellable_is_cancelled (request->cancellable);

    (void) source_object;
    if (!g_log_writer_default_would_drop (G_LOG_LEVEL_DEBUG, G_LOG_DOMAIN))
    {
        g_autofree char *uri = nautilus_file_info_get_uri (request->file);
        if (cancelled)
            g_debug ("%s: anulowano / cancelled", uri);
        else
            g_debug ("%s: %s, %.3f s, %u×%u", uri, media && media->format ? media->format : "?",
                     media ? media->seconds : 0.0, media ? media->width : 0, media ? media->height : 0);
    }

    /* Po cancel_update() Nautilus nie czeka już na odpowiedź i nie wolno jej wysłać. */
    if (!cancelled)
    {
        vsd_set_attributes (request->file, media);
        nautilus_info_provider_update_complete_invoke (request->update_complete,
                                                       request->provider,
                                                       (NautilusOperationHandle *) request,
                                                       NAUTILUS_OPERATION_COMPLETE);
    }
    vsd_request_free (request);
}

static NautilusOperationResult
vsd_update_file_info (NautilusInfoProvider     *provider,
                      NautilusFileInfo         *file,
                      GClosure                 *update_complete,
                      NautilusOperationHandle **handle)
{
    VsdRequest *request;
    VsdJob *job;
    guint hints;
    g_autoptr (GTask) task = NULL;

    /* Atrybuty ustawiamy każdemu plikowi (choćby puste), żeby strcmp()
     * w sortowaniu Nautilusa porównywał spójnie całą listę. */
    if (!vsd_is_candidate (file, &hints))
    {
        vsd_set_attributes (file, NULL);
        return NAUTILUS_OPERATION_COMPLETE;
    }

    request = g_new0 (VsdRequest, 1);
    request->update_complete = g_closure_ref (update_complete);
    request->provider = g_object_ref (provider);
    request->file = g_object_ref (file);
    request->cancellable = g_cancellable_new ();

    job = g_new0 (VsdJob, 1);
    job->location = nautilus_file_info_get_location (file);
    job->hints = hints;

    task = g_task_new (NULL, request->cancellable, vsd_probe_done, request);
    g_task_set_source_tag (task, vsd_update_file_info);
    g_task_set_task_data (task, job, (GDestroyNotify) vsd_job_free);
    g_task_run_in_thread (task, vsd_probe_thread);

    *handle = (NautilusOperationHandle *) request;
    return NAUTILUS_OPERATION_IN_PROGRESS;
}

static void
vsd_cancel_update (NautilusInfoProvider    *provider,
                   NautilusOperationHandle *handle)
{
    VsdRequest *request = (VsdRequest *) handle;

    (void) provider;
    /* Zwolnienie nastąpi w vsd_probe_done(), które GTask wywoła zawsze. */
    g_cancellable_cancel (request->cancellable);
}

static void
vsd_info_provider_iface_init (NautilusInfoProviderInterface *iface)
{
    iface->update_file_info = vsd_update_file_info;
    iface->cancel_update = vsd_cancel_update;
}

/* ===================================================================== */
/*  Punkty wejścia modułu                                                 */
/* ===================================================================== */

static GType vsd_types[1];

void
nautilus_module_initialize (GTypeModule *module)
{
    video_size_duration_provider_register_type (module);
    vsd_types[0] = video_size_duration_provider_get_type ();
    g_debug ("Nautilus Video Size and Duration: załadowano / loaded");
}

void
nautilus_module_shutdown (void)
{
}

void
nautilus_module_list_types (const GType **types,
                            int          *num_types)
{
    *types = vsd_types;
    *num_types = G_N_ELEMENTS (vsd_types);
}
C_SOURCE
}

# -----------------------------------------------------------------------------
#  Dystrybucja / distribution
# -----------------------------------------------------------------------------
OS_ID="" OS_LIKE="" OS_VERSION="" OS_PRETTY="" FAMILY="unknown"
PKGS=()

# Pole z os-release czytane jako tekst (bez wykonywania pliku: jego zmienne,
# np. NAME czy VERSION, kolidowałyby ze zmiennymi skryptu).
os_field() {
    sed -n "s/^$1=//p" "$OS_RELEASE" 2>/dev/null | head -n1 |
        sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

detect_distro() {
    if [[ -r "$OS_RELEASE" ]]; then
        OS_ID="$(os_field ID)"
        OS_LIKE="$(os_field ID_LIKE)"
        OS_VERSION="$(os_field VERSION_ID)"
        OS_PRETTY="$(os_field PRETTY_NAME)"
        OS_PRETTY="${OS_PRETTY:-$OS_ID}"
    fi

    local word
    for word in $OS_ID $OS_LIKE; do
        case "$word" in
            fedora|rhel|centos|rocky|almalinux|nobara|ultramarine)
                FAMILY=fedora; PKGS=(gcc pkgconf-pkg-config nautilus-devel); break ;;
            debian|ubuntu|linuxmint|pop|elementary|zorin|kali|raspbian|neon|devuan)
                FAMILY=debian; PKGS=(gcc libc6-dev pkg-config libnautilus-extension-dev); break ;;
            arch|archlinux|manjaro|endeavouros|cachyos|garuda|artix)
                # Na Archu nagłówki i .pc są w pakiecie libnautilus-extension (zależność nautilusa).
                FAMILY=arch; PKGS=(gcc pkgconf libnautilus-extension); break ;;
            opensuse*|suse|sles)
                FAMILY=suse; PKGS=(gcc pkg-config nautilus-devel); break ;;
        esac
    done
}

pkg_installed() {
    local p
    for p in "$@"; do
        case "$FAMILY" in
            fedora|suse) rpm -q "$p" >/dev/null 2>&1 || return 1 ;;
            debian)      dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null | grep -qx installed || return 1 ;;
            arch)        pacman -Q "$p" >/dev/null 2>&1 || return 1 ;;
            *)           return 1 ;;
        esac
    done
}

# Uruchamia polecenie jako root: sudo, doas albo pkexec.
as_root() {
    if command -v sudo >/dev/null; then sudo "$@"
    elif command -v doas >/dev/null; then doas "$@"
    elif command -v pkexec >/dev/null; then pkexec "$@"
    else
        die "$(t 'Brak sudo, doas i pkexec. Uruchom jako root: %s' 'No sudo, doas or pkexec found. Run as root: %s')" "$*"
    fi
}

install_deps() {
    if [[ "$FAMILY" == unknown ]]; then
        warn "$(t 'Nieznana dystrybucja (%s); pomijam instalację pakietów.' 'Unknown distribution (%s); skipping package installation.')" "${OS_PRETTY:-?}"
        return 0
    fi
    pkg_installed "${PKGS[@]}" && return 0

    msg "$(t 'Instalacja zależności: %s' 'Installing dependencies: %s')" "${PKGS[*]}"
    case "$FAMILY" in
        fedora) as_root dnf install -y "${PKGS[@]}" ;;
        debian)
            if ! as_root apt-get install -y "${PKGS[@]}"; then
                msg "$(t 'Odświeżam listy pakietów i próbuję ponownie' 'Refreshing package lists and retrying')"
                as_root apt-get update
                as_root apt-get install -y "${PKGS[@]}"
            fi ;;
        arch)   as_root pacman -S --needed --noconfirm "${PKGS[@]}" ;;
        suse)   as_root zypper --non-interactive install "${PKGS[@]}" ;;
    esac
}

hint_dev_package() {
    case "$FAMILY" in
        fedora) printf 'sudo dnf install nautilus-devel' ;;
        debian) printf 'sudo apt install libnautilus-extension-dev' ;;
        arch)   printf 'sudo pacman -S libnautilus-extension' ;;
        suse)   printf 'sudo zypper install nautilus-devel' ;;
        *)      t 'pakiet nagłówków libnautilus-extension (API 4)' 'the libnautilus-extension (API 4) headers package' ;;
    esac
}

check_system() {
    [[ $EUID -ne 0 ]] ||
        die "$(t 'Uruchom jako zwykły użytkownik; uprawnienia roota zostaną użyte tylko do pakietów i kopiowania.' 'Run as a regular user; root is only used for packages and copying.')"

    if [[ -e /run/ostree-booted ]]; then
        die "$(t 'System atomowy (Silverblue/Kinoite, rpm-ostree): /usr jest tylko do odczytu, więc instalator nie może dodać rozszerzenia. Zobacz README, sekcja „Ograniczenia”.' 'Atomic system (Silverblue/Kinoite, rpm-ostree): /usr is read-only, so the installer cannot add the extension. See README, section "Limitations".')"
    fi

    case "$FAMILY" in
        unknown) warn "$(t 'Nie rozpoznano dystrybucji: %s' 'Distribution not recognised: %s')" "${OS_PRETTY:-?}" ;;
        *)       msg "$(t 'System: %s (%s)' 'System: %s (%s)')" "${OS_PRETTY:-$OS_ID}" "$FAMILY" ;;
    esac

    command -v nautilus >/dev/null || die "$(t 'Nie znaleziono Nautilusa (Pliki).' 'Nautilus (Files) not found.')"
    local major
    major="$(nautilus --version 2>/dev/null | grep -oE '[0-9]+' | head -n1 || true)"
    if [[ -n "$major" && "$major" -lt 43 ]]; then
        die "$(t 'Wymagany Nautilus 43 lub nowszy (wykryto %s). Starsze wersje mają API 3.' 'Nautilus 43 or newer is required (found %s). Older versions use API 3.')" "$major"
    fi
}

# -----------------------------------------------------------------------------
#  Budowanie i instalacja / building and installing
# -----------------------------------------------------------------------------
compile() {
    local out="$1" flags
    command -v gcc >/dev/null || die "$(t 'Brak kompilatora gcc.' 'gcc compiler not found.')"
    command -v pkg-config >/dev/null || die "$(t 'Brak pkg-config.' 'pkg-config not found.')"
    if ! pkg-config --exists "$PC"; then
        if pkg-config --exists libnautilus-extension; then
            die "$(t 'Znaleziono tylko API 3 (Nautilus < 43). Wymagany Nautilus 43+.' 'Only API 3 found (Nautilus < 43). Nautilus 43+ is required.')"
        fi
        die "$(t 'Brak %s.pc. Zainstaluj: %s' 'Missing %s.pc. Install: %s')" "$PC" "$(hint_dev_package)"
    fi

    write_source "$BUILD_DIR/$EXT_NAME.c"
    flags="$(pkg-config --cflags --libs "$PC" gio-2.0)"
    msg "$(t 'Kompilacja (libnautilus-extension %s)' 'Compiling (libnautilus-extension %s)')" "$(pkg-config --modversion "$PC" 2>/dev/null || echo '?')"
    # shellcheck disable=SC2086
    gcc -std=gnu11 -O2 -g -Wall -Wextra -fPIC -shared \
        -Wl,--no-undefined -Wl,-z,relro,-z,now \
        -o "$out" "$BUILD_DIR/$EXT_NAME.c" $flags
}

extension_dir() {
    local dir
    dir="$(pkg-config --variable=extensiondir "$PC" 2>/dev/null || true)"
    if [[ -z "$dir" ]]; then
        local d
        for d in /usr/lib64/nautilus/extensions-4 /usr/lib/*/nautilus/extensions-4 /usr/lib/nautilus/extensions-4; do
            [[ -d "$d" ]] && { dir="$d"; break; }
        done
    fi
    printf '%s\n' "${dir:-/usr/lib/nautilus/extensions-4}"
}

# Wszystkie miejsca, gdzie mogła trafić wtyczka (do usuwania).
candidate_dirs() {
    local seen="" d
    for d in "$(extension_dir)" /usr/lib64/nautilus/extensions-4 /usr/lib/nautilus/extensions-4 /usr/lib/*/nautilus/extensions-4; do
        [[ -d "$d" && " $seen " != *" $d "* ]] || continue
        seen="$seen $d"
        printf '%s\n' "$d"
    done
}

remove_files() {
    local name removed=1 d
    for name in "$@"; do
        while IFS= read -r d; do
            if [[ -e "$d/$name" ]]; then
                msg "$(t 'Usuwanie %s' 'Removing %s')" "$d/$name"
                as_root rm -f "$d/$name"
                removed=0
            fi
        done < <(candidate_dirs)
    done
    return $removed
}

have_schema_key() {
    command -v gsettings >/dev/null &&
        gsettings list-keys "$SCHEMA" 2>/dev/null | grep -qx "$KEY"
}

columns_default_add() {
    have_schema_key || { warn "$(t 'Brak schematu %s; pomijam.' 'Schema %s not found; skipping.')" "$SCHEMA"; return 0; }
    local cur col
    cur="$(gsettings get "$SCHEMA" "$KEY")"
    [[ "$cur" == "@as []" || "$cur" == "[]" ]] && cur="['name']"
    for col in "${NVSD_COLUMNS[@]}"; do
        [[ "$cur" == *"'$col'"* ]] || cur="${cur%]}, '$col']"
    done
    gsettings set "$SCHEMA" "$KEY" "$cur"
    msg "$(t 'Kolumny będą domyślnie widoczne (folderów z własnym układem kolumn to nie zmienia).' 'Columns will be visible by default (folders with their own column layout are not affected).')"
}

columns_default_remove() {
    have_schema_key || return 0
    local cur col
    cur="$(gsettings get "$SCHEMA" "$KEY")"
    for col in "${NVSD_COLUMNS[@]}"; do
        cur="$(sed -e "s/, '$col'//g" -e "s/'$col', //g" -e "s/'$col'//g" <<<"$cur")"
    done
    if [[ "$cur" == "[]" ]]; then
        gsettings reset "$SCHEMA" "$KEY"
    elif [[ "$cur" != "$(gsettings get "$SCHEMA" "$KEY")" ]]; then
        gsettings set "$SCHEMA" "$KEY" "$cur"
    fi
}

restart_nautilus() {
    pgrep -x nautilus >/dev/null 2>&1 || return 0
    if [[ -t 0 ]]; then
        local answer
        read -r -p "$(t 'Zrestartować Nautilusa teraz? Przerwie to trwające kopiowanie plików. [T/n] ' 'Restart Nautilus now? This interrupts running file copies. [Y/n] ')" answer ||
            answer=n
        if [[ -z "$answer" || "$answer" =~ ^[TtYy] ]]; then
            nautilus -q 2>/dev/null || true
            msg "$(t 'Nautilus zamknięty; otwórz Pliki ponownie.' 'Nautilus closed; open Files again.')"
            return 0
        fi
    fi
    warn "$(t 'Zmiany zadziałają po restarcie Nautilusa: nautilus -q' 'Changes take effect after restarting Nautilus: nautilus -q')"
}

# -----------------------------------------------------------------------------
#  Polecenia / commands
# -----------------------------------------------------------------------------
cmd_install() {
    local show_by_default=0 arg dir
    for arg in "$@"; do
        case "$arg" in
            --show-by-default) show_by_default=1 ;;
            *) die "$(t 'Nieznana opcja: %s' 'Unknown option: %s')" "$arg" ;;
        esac
    done

    detect_distro
    check_system
    install_deps
    compile "$BUILD_DIR/$SO"

    remove_files "$OLD_SO" &&
        msg "$(t 'Usunięto poprzednią wersję (tylko MP4/MOV), żeby kolumny się nie dublowały.' 'Removed the previous version (MP4/MOV only) so the columns are not duplicated.')"

    dir="$(extension_dir)"
    msg "$(t 'Instalacja do %s' 'Installing to %s')" "$dir/$SO"
    as_root install -Dm755 "$BUILD_DIR/$SO" "$dir/$SO"
    if command -v restorecon >/dev/null; then
        as_root restorecon "$dir/$SO" || true   # SELinux (Fedora)
    fi

    (( show_by_default )) && columns_default_add
    restart_nautilus

    if [[ "$UI_LANG" == pl ]]; then
        cat <<EOF

Gotowe. Aby zobaczyć kolumny:
  1. Przełącz widok na listę (Ctrl+1).
  2. Strzałka przy przycisku widoku → „Widoczne kolumny…” →
     zaznacz „Czas trwania”, „Szerokość (px)”, „Wysokość (px)”.
  3. Kliknij nagłówek kolumny, żeby sortować (ponownie: odwrotna kolejność).

Język kolumn wynika z języka sesji (polski lub angielski).
Usunięcie:  $0 uninstall
EOF
    else
        cat <<EOF

Done. To see the columns:
  1. Switch to the list view (Ctrl+1).
  2. Arrow next to the view button → "Visible Columns…" →
     tick "Duration", "Width (px)", "Height (px)".
  3. Click a column header to sort (click again to reverse).

Column labels follow the session language (Polish or English).
Uninstall:  $0 uninstall
EOF
    fi
}

cmd_uninstall() {
    [[ $EUID -ne 0 ]] || die "$(t 'Uruchom jako zwykły użytkownik.' 'Run as a regular user.')"
    detect_distro
    columns_default_remove
    if remove_files "$SO" "$OLD_SO"; then
        restart_nautilus
        msg "$(t 'Usunięto. Pakiety deweloperskie zostały; usuń je ręcznie, jeśli nie są potrzebne.' 'Removed. Development packages were kept; remove them manually if not needed.')"
    else
        warn "$(t 'Rozszerzenie nie było zainstalowane.' 'The extension was not installed.')"
    fi
}

cmd_build() {
    detect_distro
    compile "$PWD/$SO"
    msg "$(t 'Zbudowano: %s' 'Built: %s')" "$PWD/$SO"
}

cmd_source() {
    write_source "$PWD/$EXT_NAME.c"
    msg "$(t 'Zapisano: %s' 'Written: %s')" "$PWD/$EXT_NAME.c"
}

cmd_help() {
    if [[ "$UI_LANG" == pl ]]; then
        cat <<EOF
Nautilus Video Size and Duration $NVSD_VERSION — kolumny czasu trwania i rozmiaru obrazu w Nautilusie

Użycie: $0 [polecenie] [opcje]

Polecenia:
  install       kompiluje i instaluje (domyślne)
  uninstall     usuwa rozszerzenie (także wersję 1)
  build         tylko kompiluje $SO do bieżącego katalogu
  source        zapisuje kod C do bieżącego katalogu
  help          ta pomoc

Opcje:
  --show-by-default   (install) kolumny widoczne domyślnie we wszystkich folderach
  --lang pl|en        język komunikatów (domyślnie z LANG/LANGUAGE)

Obsługiwane: MP4 M4V M4A M4B MOV 3GP · MKV MKA WEBM · AVI · WMV WMA ASF
             OGG OGA OGV OPUS SPX · FLAC · WAV · MP3 MP2 · AAC
Licencja: EUPL-1.2
EOF
    else
        cat <<EOF
Nautilus Video Size and Duration $NVSD_VERSION — duration and frame size columns for Nautilus

Usage: $0 [command] [options]

Commands:
  install       compile and install (default)
  uninstall     remove the extension (including version 1)
  build         only compile $SO into the current directory
  source        write the C source into the current directory
  help          this help

Options:
  --show-by-default   (install) show the columns by default in every folder
  --lang pl|en        message language (default from LANG/LANGUAGE)

Supported: MP4 M4V M4A M4B MOV 3GP · MKV MKA WEBM · AVI · WMV WMA ASF
           OGG OGA OGV OPUS SPX · FLAC · WAV · MP3 MP2 · AAC
Licence: EUPL-1.2
EOF
    fi
}

set -- "${ARGS[@]+"${ARGS[@]}"}"
case "${1:-install}" in
    install)        shift || true; cmd_install "$@" ;;
    uninstall)      cmd_uninstall ;;
    build)          cmd_build ;;
    source)         cmd_source ;;
    help|-h|--help) cmd_help ;;
    --version)      printf '%s\n' "$NVSD_VERSION" ;;
    *)              die "$(t 'Nieznane polecenie: %s (install | uninstall | build | source | help)' 'Unknown command: %s (install | uninstall | build | source | help)')" "$1" ;;
esac
