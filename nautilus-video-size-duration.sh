#!/usr/bin/env bash
# Nautilus Video Size and Duration v2.6.0
# Copyright (C) 2026 M.T. Jaroszek
# SPDX-License-Identifier: EUPL-1.2
set -euo pipefail

readonly NVSD_VERSION="2.6.0"
readonly EXT_NAME="nautilus-video-size-duration"
readonly SO="lib${EXT_NAME}.so"
readonly OLD_SO="libnautilus-video-duration.so"
readonly PC="libnautilus-extension-4"
readonly SCHEMA="org.gnome.nautilus.list-view"
readonly KEY="default-visible-columns"
readonly NVSD_COLUMNS=(video_duration video_width video_height)
readonly OS_RELEASE="${NVSD_OS_RELEASE:-/etc/os-release}"

readonly THUMB_BIN="/usr/local/bin/${EXT_NAME}-thumbnailer"
readonly THUMB_FILE="${EXT_NAME}.thumbnailer"
readonly THUMB_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/thumbnailers"
readonly THUMB_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/thumbnails"
readonly VIDEO_MIMES="video/mp4;video/x-m4v;video/mp4v-es;video/quicktime;video/3gpp;video/3gp;video/3gpp2;video/matroska;video/x-matroska;video/webm;video/x-msvideo;video/msvideo;video/vnd.avi;video/avi;video/x-avi;video/divx;video/vnd.divx;video/x-ms-wmv;video/x-ms-asf;video/x-ms-wm;video/ogg;video/x-ogg;video/x-theora+ogg;video/x-theora;video/x-ogm+ogg;application/vnd.ms-asf;"
readonly AUDIO_MIMES="audio/mpeg;audio/mp3;audio/x-mp3;audio/mpg;audio/x-mpeg;audio/mp2;audio/x-mp2;audio/mp4;audio/m4a;audio/x-m4a;audio/x-m4b;audio/aac;audio/x-aac;audio/x-hx-aac-adts;audio/flac;audio/x-flac;audio/ogg;audio/x-ogg;audio/vorbis;audio/x-vorbis;audio/x-vorbis+ogg;audio/opus;audio/x-opus+ogg;audio/x-speex;audio/x-speex+ogg;audio/x-flac+ogg;audio/wav;audio/x-wav;audio/vnd.wave;audio/wave;audio/x-ms-wma;audio/matroska;audio/x-matroska;audio/webm;application/ogg;"
readonly MEDIA_EXT_RE='mp4|m4v|m4a|m4b|mov|3gp|3g2|mkv|mka|webm|avi|wmv|wma|asf|ogg|oga|ogv|opus|spx|flac|wav|mp3|mp2|aac'

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

t() { if [[ "$UI_LANG" == pl ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

msg()  { local f="$1"; shift; printf "\033[1;34m==>\033[0m $f\n" "$@"; }
warn() { local f="$1"; shift; printf "\033[1;33m%s\033[0m $f\n" "$(t 'Uwaga:' 'Warning:')" "$@" >&2; }
die()  { local f="$1"; shift; printf "\033[1;31m%s\033[0m $f\n" "$(t 'Błąd:' 'Error:')" "$@" >&2; exit 1; }

BUILD_DIR="$(mktemp -d -t "${EXT_NAME}.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

write_source() {
cat > "$1" <<'C_SOURCE'
/*
 * Nautilus Video Size and Duration
 * Copyright (C) 2026 M.T. Jaroszek
 * SPDX-License-Identifier: EUPL-1.2
 */
#define _GNU_SOURCE
#define G_LOG_DOMAIN "VideoSizeDuration"

#ifndef VSD_THUMBNAILER
#include <nautilus-extension.h>
#include <gmodule.h>
#endif
#include <gio/gio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#define VSD_ATTR_DURATION "video_duration"
#define VSD_ATTR_WIDTH    "video_width"
#define VSD_ATTR_HEIGHT   "video_height"

#define VSD_MAX_MEM_READ  (16u * 1024u * 1024u)
#define VSD_MAX_TRACKS    64
#define VSD_MAX_LOOP      2000000u
#define VSD_MAX_SECONDS   1e7
#define VSD_MAX_DIMENSION 65535u

#define FOURCC(a, b, c, d) \
    (((guint32) (a) << 24) | ((guint32) (b) << 16) | ((guint32) (c) << 8) | (guint32) (d))

#ifndef VSD_THUMBNAILER

typedef struct
{
    const char *lang;
    const char *duration_label, *duration_desc;
    const char *width_label, *width_desc;
    const char *height_label, *height_desc;
    const char *sort_menu, *sort_tip, *sort_section;
    const char *sort_items[6];
} VsdStrings;

static const VsdStrings vsd_strings[] = {
    { "en",
      "Duration",       "Playing time of audio and video files",
      "Width (px)",     "Video frame width in pixels",
      "Height (px)",    "Video frame height in pixels",
      "Sort (audio/video)", "Sort the folder by duration or video frame size", "Audio and Video",
      { "▼ Duration", "▲ Duration",
        "▼ Width",    "▲ Width",
        "▼ Height",   "▲ Height" } },
    { "pl",
      "Czas trwania",   "Czas odtwarzania plików audio i wideo",
      "Szerokość (px)", "Szerokość klatki wideo w pikselach",
      "Wysokość (px)",  "Wysokość klatki wideo w pikselach",
      "Porządkowanie (audio/wideo)", "Porządkuje folder według czasu trwania lub rozmiaru obrazu", "Audio i wideo",
      { "▼ Czas trwania", "▲ Czas trwania",
        "▼ Szerokość",    "▲ Szerokość",
        "▼ Wysokość",     "▲ Wysokość" } },
};

static const VsdStrings *
vsd_lookup_strings (void)
{
    for (const char *const *name = g_get_language_names (); *name != NULL; name++)
    {
        for (gsize i = 0; i < G_N_ELEMENTS (vsd_strings); i++)
        {
            gsize n = strlen (vsd_strings[i].lang);

            if (strncmp (*name, vsd_strings[i].lang, n) == 0 &&
                strchr ("_.@", (*name)[n]) != NULL)
                return &vsd_strings[i];
        }
    }
    return &vsd_strings[0];
}

static const VsdStrings *
vsd_pick_strings (void)
{
    static gsize picked = 0;

    if (g_once_init_enter (&picked))
        g_once_init_leave (&picked, (gsize) vsd_lookup_strings ());
    return (const VsdStrings *) picked;
}
#endif

#define VSD_CACHE_SIZE 4096
#define VSD_CACHE_MIN  256

typedef struct
{
    int           fd;
    GInputStream *in;
    GCancellable *cancellable;
    guint64       size;
    guint64       cache_off;
    gsize         cache_len;
    gboolean      cache_used;
    guint8        cache[VSD_CACHE_SIZE];
} VsdReader;

typedef struct
{
    double      seconds;
    guint32     width;
    guint32     height;
    const char *format;
} VsdMedia;

enum
{
    VSD_HINT_MPEG_AUDIO = 1 << 0,
};

static inline guint16 rd_be16 (const guint8 *p) { return (guint16) ((p[0] << 8) | p[1]); }
static inline guint32 rd_be24 (const guint8 *p) { return ((guint32) p[0] << 16) | ((guint32) p[1] << 8) | p[2]; }
static inline guint32 rd_be32 (const guint8 *p) { return ((guint32) p[0] << 24) | ((guint32) p[1] << 16) | ((guint32) p[2] << 8) | p[3]; }
static inline guint64 rd_be64 (const guint8 *p) { return ((guint64) rd_be32 (p) << 32) | rd_be32 (p + 4); }
static inline guint16 rd_le16 (const guint8 *p) { return (guint16) (p[0] | (p[1] << 8)); }
static inline guint32 rd_le32 (const guint8 *p) { return p[0] | ((guint32) p[1] << 8) | ((guint32) p[2] << 16) | ((guint32) p[3] << 24); }
static inline guint64 rd_le64 (const guint8 *p) { return rd_le32 (p) | ((guint64) rd_le32 (p + 4) << 32); }

static gboolean
vsd_read_raw (VsdReader *r,
              guint64    offset,
              void      *buf,
              gsize      len)
{
    gsize got = 0;

    if (g_cancellable_is_cancelled (r->cancellable))
        return FALSE;
    if (r->fd >= 0)
    {
        guint8 *p = buf;

        while (len > 0)
        {
            ssize_t n = pread (r->fd, p, len, (off_t) offset);

            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0)
                return FALSE;
            p += n;
            offset += (guint64) n;
            len -= (gsize) n;
        }
        return TRUE;
    }
    if (!g_seekable_seek (G_SEEKABLE (r->in), (goffset) offset, G_SEEK_SET, r->cancellable, NULL))
        return FALSE;
    if (!g_input_stream_read_all (r->in, buf, len, &got, r->cancellable, NULL))
        return FALSE;
    return got == len;
}

static gboolean
vsd_read_at (VsdReader *r,
             guint64    offset,
             void      *buf,
             gsize      len)
{
    if (len == 0)
        return TRUE;
    if (offset > (guint64) G_MAXINT64 || offset >= r->size || len > r->size - offset)
        return FALSE;
    if (len > VSD_CACHE_SIZE)
        return vsd_read_raw (r, offset, buf, len);
    if (r->cache_len == 0 || offset < r->cache_off || offset + len > r->cache_off + r->cache_len)
    {
        gsize want = (r->cache_len == 0 || r->cache_used) ? VSD_CACHE_SIZE : MAX (len, VSD_CACHE_MIN);
        gsize fill = (gsize) MIN ((guint64) want, r->size - offset);

        r->cache_len = 0;
        if (!vsd_read_raw (r, offset, r->cache, fill))
            return FALSE;
        r->cache_off = offset;
        r->cache_len = fill;
        r->cache_used = FALSE;
    }
    else
        r->cache_used = TRUE;
    memcpy (buf, r->cache + (offset - r->cache_off), len);
    return TRUE;
}

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
    BOX_MFRA = FOURCC ('m', 'f', 'r', 'a'), BOX_MFRO = FOURCC ('m', 'f', 'r', 'o'),
    BOX_TFRA = FOURCC ('t', 'f', 'r', 'a'),
    HDLR_VIDE = FOURCC ('v', 'i', 'd', 'e'),
};

typedef struct
{
    guint32 type;
    guint64 start;
    guint64 size;
    guint64 hdr;
} VsdBox;

typedef struct
{
    guint32       type;
    const guint8 *data;
    gsize         len;
} VsdMemBox;

typedef struct
{
    guint32 id;
    guint32 timescale;
    guint64 end;
    guint32 trex_duration;
} VsdTrack;

typedef struct
{
    guint32  timescale;
    guint64  duration;
    guint64  mehd;
    gboolean fragmented;
    gboolean saw_moof;
    gboolean missing_tfdt;
    guint    trafs;
    GArray  *tracks;
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
        size = end - offset;
    }

    if (size < box->hdr || size > end - offset)
        return FALSE;

    box->start = offset;
    box->size = size;
    return TRUE;
}

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
            *duration = 0;
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
                gsize mo = p[0] == 1 ? 52 : 40;

                id = rd_be32 (p + (p[0] == 1 ? 20 : 12));
                have_id = TRUE;
                if (n >= mo + 44)
                {
                    gint32 a = (gint32) rd_be32 (p + mo), b = (gint32) rd_be32 (p + mo + 4);
                    gint32 c = (gint32) rd_be32 (p + mo + 12), d = (gint32) rd_be32 (p + mo + 16);

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

    while (vsd_mem_next_box (buf, len, &pos, &box))
    {
        if (box.type == BOX_TFHD && box.len >= 8)
        {
            gsize p = 8;

            tfhd_flags = rd_be32 (box.data) & 0xffffff;
            track_id = rd_be32 (box.data + 4);
            if (tfhd_flags & 0x000001) p += 8;
            if (tfhd_flags & 0x000002) p += 4;
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
    movie->trafs++;
    if (!have_tfdt)
        movie->missing_tfdt = TRUE;

    if (!(tfhd_flags & 0x000008))
        default_duration = track->trex_duration;

    pos = 0;
    while (vsd_mem_next_box (buf, len, &pos, &box))
    {
        guint32 flags, count;
        gsize p = 8;

        if (box.type != BOX_TRUN || box.len < 8)
            continue;

        flags = rd_be32 (box.data) & 0xffffff;
        count = rd_be32 (box.data + 4);
        if (flags & 0x000001) p += 4;
        if (flags & 0x000004) p += 4;

        if (flags & 0x000100)
        {
            gsize stride = 4 * (gsize) (((flags & 0x100) != 0) + ((flags & 0x200) != 0) +
                                        ((flags & 0x400) != 0) + ((flags & 0x800) != 0));

            if (p > box.len || (box.len - p) / stride < count)
                continue;
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
vsd_bmff_mfra_tail (VsdReader *r,
                    guint64    min_off,
                    guint64   *moof_off)
{
    guint8 t[16];
    guint64 size, result = G_MAXUINT64;
    g_autofree guint8 *buf = NULL;
    VsdMemBox box;
    gsize pos = 8;

    if (r->size < 32 || !vsd_read_at (r, r->size - 16, t, sizeof t) ||
        rd_be32 (t) != 16 || rd_be32 (t + 4) != BOX_MFRO)
        return FALSE;
    size = rd_be32 (t + 12);
    if (size < 24 || size > r->size || (buf = vsd_read_alloc (r, r->size - size, size)) == NULL ||
        rd_be32 (buf) != size || rd_be32 (buf + 4) != BOX_MFRA)
        return FALSE;

    while (vsd_mem_next_box (buf, (gsize) size, &pos, &box))
    {
        guint32 v, lens, count;
        gsize tsz, osz, esz, p;
        guint64 track_max = 0;

        if (box.type != BOX_TFRA || box.len < 12)
            continue;
        v = box.data[0];
        lens = rd_be32 (box.data + 8);
        tsz = v == 1 ? 8 : 4;
        osz = tsz;
        esz = tsz + osz + ((lens >> 4) & 3) + 1 + ((lens >> 2) & 3) + 1 + (lens & 3) + 1;
        if (box.len < 16)
            continue;
        count = rd_be32 (box.data + 12);
        p = 16;
        if ((box.len - p) / esz < count)
            continue;
        for (guint32 i = 0; i < count; i++, p += esz)
        {
            guint64 off = osz == 8 ? rd_be64 (box.data + p + tsz) : rd_be32 (box.data + p + tsz);
            track_max = MAX (track_max, off);
        }
        if (track_max > 0)
            result = MIN (result, track_max);
    }
    if (result == G_MAXUINT64 || result < min_off || result >= r->size)
        return FALSE;
    *moof_off = result;
    return TRUE;
}

static guint
vsd_bmff_parse_moofs (VsdReader *r,
                      guint64    off,
                      VsdMovie  *movie)
{
    VsdBox box;
    guint n = 0;

    for (guint i = 0; i < VSD_MAX_LOOP && vsd_read_box (r, off, r->size, &box); i++)
    {
        if (g_cancellable_is_cancelled (r->cancellable) || !vsd_fourcc_printable (box.type))
            break;
        if (box.type == BOX_MOOF)
        {
            vsd_parse_moof (r, &box, movie);
            n++;
        }
        off += box.size;
    }
    return n;
}

#define VSD_TAIL_MOOFS 8
#define VSD_TAIL_MIN   (256u * 1024u)
#define VSD_TAIL_MAX   (8u * 1024u * 1024u)
#define VSD_WALK_FRAGS 16u

static guint
vsd_bmff_tail_moofs (VsdReader *r,
                     guint64    min_off,
                     guint64    window,
                     VsdBox    *ring)
{
    guint64 start = r->size > window ? r->size - window : 0;
    g_autofree guint8 *buf = NULL;
    gsize len, pos = 4;
    guint seen = 0;

    start = MAX (start, min_off);
    if (start >= r->size)
        return 0;
    len = (gsize) (r->size - start);
    buf = vsd_read_alloc (r, start, len);
    if (buf == NULL || len < 24)
        return 0;
    while (pos + 20 <= len)
    {
        guint8 *hit = memmem (buf + pos, len - pos - 16, "moof", 4);
        gsize at;
        guint32 size;

        if (hit == NULL)
            break;
        at = (gsize) (hit - buf);
        pos = at + 1;
        size = rd_be32 (buf + at - 4);
        if (size < 24 || (guint64) size > r->size - (start + at - 4) ||
            memcmp (buf + at + 8, "mfhd", 4) != 0 || rd_be32 (buf + at + 4) != 16)
            continue;
        ring[seen % VSD_TAIL_MOOFS] = (VsdBox) { BOX_MOOF, start + at - 4, size, 8 };
        seen++;
        pos = at + 20;
    }
    return seen;
}

static guint64
vsd_bmff_fragment_size (VsdReader *r,
                        guint64    off)
{
    guint64 moof = G_MAXUINT64;
    VsdBox box;

    for (guint i = 0; i < 8 && vsd_read_box (r, off, r->size, &box); i++)
    {
        if (box.type == BOX_MOOF && moof != G_MAXUINT64)
            return box.start - moof;
        if (box.type == BOX_MOOF)
            moof = box.start;
        else if (box.type == BOX_MDAT && moof != G_MAXUINT64)
            return box.start + box.size - moof;
        off += box.size;
    }
    return 0;
}

static gboolean
vsd_bmff_all_tracks_updated (const VsdMovie *movie,
                             const GArray   *saved)
{
    guint updated = 0, wanted = 0;

    for (guint i = 0; i < saved->len; i++)
    {
        const VsdTrack *before = &g_array_index (saved, VsdTrack, i);

        if (before->timescale == 0)
            continue;
        wanted++;
        updated += g_array_index (movie->tracks, VsdTrack, i).end != before->end;
    }
    return updated > 0 && updated == wanted;
}

static void
vsd_bmff_fragments (VsdReader *r,
                    guint64    after_moov,
                    VsdMovie  *movie)
{
    g_autoptr (GArray) saved = g_array_copy (movie->tracks);
    VsdBox ring[VSD_TAIL_MOOFS];
    guint64 off = after_moov, moof_off = 0, frag;
    guint seen = 0;
    VsdBox box;

    if (vsd_bmff_mfra_tail (r, after_moov, &moof_off) &&
        vsd_bmff_parse_moofs (r, moof_off, movie) > 0 && movie->trafs > 0 && !movie->missing_tfdt)
        return;

    frag = vsd_bmff_fragment_size (r, after_moov);
    if (frag == 0 || (r->size - after_moov) / frag > VSD_WALK_FRAGS)
    {
        guint64 window = frag == 0 ? VSD_TAIL_MIN : CLAMP (frag * 2 + 65536, VSD_TAIL_MIN, VSD_TAIL_MAX);

        memcpy (movie->tracks->data, saved->data, saved->len * sizeof (VsdTrack));
        movie->missing_tfdt = FALSE;
        movie->trafs = 0;
        seen = vsd_bmff_tail_moofs (r, after_moov, window, ring);
        for (guint i = seen > VSD_TAIL_MOOFS ? seen - VSD_TAIL_MOOFS : 0; i < seen; i++)
            vsd_parse_moof (r, &ring[i % VSD_TAIL_MOOFS], movie);
        if (seen > 0 && !movie->missing_tfdt && vsd_bmff_all_tracks_updated (movie, saved))
            return;
    }

    memcpy (movie->tracks->data, saved->data, saved->len * sizeof (VsdTrack));
    movie->missing_tfdt = FALSE;
    movie->trafs = 0;
    seen = 0;
    for (guint i = 0; i < VSD_MAX_LOOP && vsd_read_box (r, off, r->size, &box); i++)
    {
        if (g_cancellable_is_cancelled (r->cancellable) || !vsd_fourcc_printable (box.type))
            break;
        if (box.type == BOX_MOOF)
            ring[seen++ % VSD_TAIL_MOOFS] = box;
        off += box.size;
    }
    for (guint i = seen > VSD_TAIL_MOOFS ? seen - VSD_TAIL_MOOFS : 0; i < seen; i++)
        vsd_parse_moof (r, &ring[i % VSD_TAIL_MOOFS], movie);
    if (seen == 0 || (movie->trafs > 0 && !movie->missing_tfdt))
        return;

    memcpy (movie->tracks->data, saved->data, saved->len * sizeof (VsdTrack));
    movie->missing_tfdt = FALSE;
    vsd_bmff_parse_moofs (r, after_moov, movie);
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

    while (vsd_read_box (r, off, r->size, &box))
    {
        if (g_cancellable_is_cancelled (r->cancellable) || ++boxes > VSD_MAX_LOOP)
            break;
        if (!vsd_fourcc_printable (box.type))
            break;
        off += box.size;
        if (box.type == BOX_MOOV)
        {
            vsd_parse_moov (r, &box, &movie, m);
            have_moov = TRUE;
            break;
        }
    }

    if (have_moov && movie.fragmented && movie.mehd == 0)
        vsd_bmff_fragments (r, off, &movie);

    if (have_moov)
    {
        if (movie.timescale)
            seconds = (double) movie.duration / movie.timescale;
        if (movie.fragmented && movie.timescale && movie.mehd)
            seconds = MAX (seconds, (double) movie.mehd / movie.timescale);
        if ((movie.fragmented && movie.mehd == 0) || seconds <= 0.0)
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
    MKV_SEEKHEAD    = 0x114D9B74, MKV_SEEK        = 0x4DBB,
    MKV_SEEKID      = 0x53AB,     MKV_SEEKPOS     = 0x53AC,
    MKV_CUETRACKPOS = 0xB7,       MKV_CUECLUSTER  = 0xF1,
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
    *unknown = ones;
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
                    gsize         len,
                    guint64      *cluster_pos)
{
    VsdEbml point, el, tp;
    gsize pos = 0;
    guint64 last = 0;

    *cluster_pos = 0;
    while (vsd_ebml_next (buf, len, &pos, &point))
    {
        guint64 t = 0, cp = 0;
        gboolean have_t = FALSE;
        gsize p2 = 0;

        if (point.id != MKV_CUEPOINT)
            continue;
        while (vsd_ebml_next (point.data, point.len, &p2, &el))
        {
            if (el.id == MKV_CUETIME)
            {
                t = vsd_ebml_uint (el.data, el.len);
                have_t = TRUE;
            }
            else if (el.id == MKV_CUETRACKPOS)
            {
                gsize p3 = 0;
                while (vsd_ebml_next (el.data, el.len, &p3, &tp))
                {
                    if (tp.id == MKV_CUECLUSTER)
                        cp = MAX (cp, vsd_ebml_uint (tp.data, tp.len));
                }
            }
        }
        if (have_t && t >= last)
        {
            last = t;
            *cluster_pos = cp;
        }
    }
    return last;
}

static void
vsd_mkv_parse_seekhead (const guint8 *buf,
                        gsize         len,
                        guint64      *info,
                        guint64      *tracks,
                        guint64      *cues)
{
    VsdEbml seek, el;
    gsize pos = 0;

    while (vsd_ebml_next (buf, len, &pos, &seek))
    {
        guint64 id = 0, where = 0;
        gboolean have_pos = FALSE;
        gsize p2 = 0;

        if (seek.id != MKV_SEEK)
            continue;
        while (vsd_ebml_next (seek.data, seek.len, &p2, &el))
        {
            if (el.id == MKV_SEEKID)
                id = vsd_ebml_uint (el.data, el.len);
            else if (el.id == MKV_SEEKPOS)
            {
                where = vsd_ebml_uint (el.data, el.len);
                have_pos = TRUE;
            }
        }
        if (!have_pos)
            continue;
        if (id == MKV_INFO && *info == G_MAXUINT64)
            *info = where;
        else if (id == MKV_TRACKS && *tracks == G_MAXUINT64)
            *tracks = where;
        else if (id == MKV_CUES && *cues == G_MAXUINT64)
            *cues = where;
    }
}

static guint8 *
vsd_mkv_read_element (VsdReader *r,
                      guint64    off,
                      guint64    seg_end,
                      guint32    want,
                      gsize     *len)
{
    guint32 id;
    guint64 size;
    gboolean unknown;
    gsize hl;

    if (off >= seg_end || !vsd_ebml_read_header (r, off, &id, &size, &unknown, &hl) ||
        id != want || unknown || off + hl > seg_end)
        return NULL;
    size = MIN (size, seg_end - off - hl);
    *len = (gsize) size;
    return vsd_read_alloc (r, off + hl, size);
}

static gboolean
vsd_mkv_last_cluster (VsdReader *r,
                      guint64    off,
                      guint64    seg_end,
                      guint64   *start,
                      guint64   *end)
{
    gboolean found = FALSE;

    for (guint loops = 0; off < seg_end && loops < VSD_MAX_LOOP; loops++)
    {
        guint32 id;
        guint64 size, data;
        gboolean unknown;
        gsize hl;

        if (g_cancellable_is_cancelled (r->cancellable) ||
            !vsd_ebml_read_header (r, off, &id, &size, &unknown, &hl))
            break;
        data = off + hl;
        if (data > seg_end || unknown)
            break;
        size = MIN (size, seg_end - data);
        if (id == MKV_CLUSTER)
        {
            *start = data;
            *end = data + size;
            found = TRUE;
        }
        off = data + size;
    }
    return found;
}

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
    guint64 size, off = 0, seg_start = 0, seg_end = 0, scale = 1000000, max_cue = 0, cue_cluster = 0;
    guint64 seek_info = G_MAXUINT64, seek_tracks = G_MAXUINT64, seek_cues = G_MAXUINT64;
    guint64 first_cluster = 0, last_cluster = 0, last_cluster_end = 0;
    gboolean unknown, found = FALSE, have_info = FALSE, have_tracks = FALSE, have_cues = FALSE;
    gboolean have_seekhead = FALSE, have_cluster = FALSE, walked_all = FALSE;
    double duration = 0.0;
    gsize hl, len;

    m->format = "Matroska/WebM";

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
        {
            walked_all = TRUE;
            break;
        }
        data = off + hl;
        if (data > seg_end)
            break;
        if (unknown)
        {
            if (id == MKV_CLUSTER)
                break;
            size = seg_end - data;
        }
        size = MIN (size, seg_end - data);

        if (id == MKV_INFO || id == MKV_TRACKS || id == MKV_CUES || (id == MKV_SEEKHEAD && !have_seekhead))
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
            else if (buf != NULL && id == MKV_CUES)
            {
                guint64 cp, cue = vsd_mkv_parse_cues (buf, (gsize) size, &cp);
                if (cue >= max_cue)
                {
                    max_cue = cue;
                    cue_cluster = cp;
                }
                have_cues = TRUE;
            }
            else if (buf != NULL)
            {
                vsd_mkv_parse_seekhead (buf, (gsize) size, &seek_info, &seek_tracks, &seek_cues);
                have_seekhead = TRUE;
            }
        }
        else if (id == MKV_CLUSTER)
        {
            if (!have_cluster)
                first_cluster = off;
            have_cluster = TRUE;
            last_cluster = data;
            last_cluster_end = data + size;

            if ((have_info || seek_info != G_MAXUINT64) && (have_tracks || seek_tracks != G_MAXUINT64))
                break;
        }

        if (have_info && have_tracks && duration > 0.0)
            break;
        off = data + size;
        if (off >= seg_end)
            walked_all = TRUE;
    }

    if (!have_info && seek_info != G_MAXUINT64)
    {
        g_autofree guint8 *buf = vsd_mkv_read_element (r, seg_start + seek_info, seg_end, MKV_INFO, &len);
        if (buf != NULL)
        {
            vsd_mkv_parse_info (buf, len, &scale, &duration);
            have_info = TRUE;
        }
    }
    if (!have_tracks && seek_tracks != G_MAXUINT64)
    {
        g_autofree guint8 *buf = vsd_mkv_read_element (r, seg_start + seek_tracks, seg_end, MKV_TRACKS, &len);
        if (buf != NULL)
        {
            vsd_mkv_parse_tracks (buf, len, m);
            have_tracks = TRUE;
        }
    }

    if (scale == 0)
        scale = 1000000;
    m->seconds = duration * (double) scale / 1e9;

    if (m->seconds <= 0.0)
    {
        guint64 end_ts, from = 0;

        if (!have_cues && seek_cues != G_MAXUINT64)
        {
            g_autofree guint8 *buf = vsd_mkv_read_element (r, seg_start + seek_cues, seg_end, MKV_CUES, &len);
            if (buf != NULL)
            {
                max_cue = vsd_mkv_parse_cues (buf, len, &cue_cluster);
                have_cues = TRUE;
            }
        }
        if (!walked_all && have_cluster)
        {
            from = first_cluster;
            if (have_cues && cue_cluster > 0 && seg_start + cue_cluster > first_cluster)
                from = seg_start + cue_cluster;
            if (!vsd_mkv_last_cluster (r, from, seg_end, &last_cluster, &last_cluster_end) && from != first_cluster)
                vsd_mkv_last_cluster (r, first_cluster, seg_end, &last_cluster, &last_cluster_end);
        }
        end_ts = max_cue;
        if (have_cluster)
        {
            guint64 cluster_end = vsd_mkv_cluster_end (r, last_cluster, last_cluster_end);
            end_ts = MAX (end_ts, cluster_end);
        }
        m->seconds = (double) end_ts * (double) scale / 1e9;
    }
    return have_info || have_tracks;
}

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
        size = (guint32) (len - *pos - 8);
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
            avi->dmlh_frames = rd_le32 (data);
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
            if (tag == 0xFFFE && size >= 40)
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
                data_size = r->size - data_offset;
            chunk = data_size;
            have_data = TRUE;
            if (have_fmt)
                break;
        }
        off += 8 + chunk + (chunk & 1);
    }

    if (!have_fmt || !have_data)
        return have_fmt;

    if ((tag == 1 || tag == 3 || tag == 6 || tag == 7) && block_align > 0 && sample_rate > 0)
        m->seconds = (double) (data_size / block_align) / sample_rate;
    else if (have_fact && fact > 0 && sample_rate > 0)
        m->seconds = (double) fact / sample_rate;
    else if (avg_bytes > 0)
        m->seconds = (double) data_size / avg_bytes;
    return TRUE;
}

enum { OGG_UNKNOWN, OGG_VORBIS, OGG_OPUS, OGG_FLAC, OGG_SPEEX, OGG_THEORA };

typedef struct
{
    guint32  serial;
    int      codec;
    guint32  rate;
    guint32  preskip;
    guint32  frn, frd;
    guint8   shift;
    gboolean theora_old;
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

static guint32
vsd_ogg_crc (const guint8 *p,
             gsize         len)
{
    guint32 crc = 0;

    for (gsize i = 0; i < 22; i++)
        crc = (crc << 8) ^ vsd_ogg_crc_table[((crc >> 24) & 0xff) ^ p[i]];
    for (gsize i = 22; i < 26; i++)
        crc = (crc << 8) ^ vsd_ogg_crc_table[(crc >> 24) & 0xff];
    for (gsize i = 26; i < len; i++)
        crc = (crc << 8) ^ vsd_ogg_crc_table[((crc >> 24) & 0xff) ^ p[i]];
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
        const guint8 *si = b + 13 + 4;
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
        vsd_media_add_video (m, rd_be24 (b + 14), rd_be24 (b + 17));
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

static gboolean
vsd_ogg_scan_tail (VsdReader    *r,
                   gsize         tail,
                   VsdOggStream *streams,
                   int           count)
{
    guint64 start = r->size > tail ? r->size - tail : 0;
    gsize len = (gsize) (r->size - start);
    g_autofree guint8 *buf = vsd_read_alloc (r, start, len);
    g_autoptr (GArray) hits = NULL;
    gboolean any = FALSE;
    int pending = count;
    gsize pos = 0;

    if (buf == NULL)
        return FALSE;

    hits = g_array_sized_new (FALSE, FALSE, sizeof (gsize), 64);
    while (pos + 27 <= len)
    {
        guint8 *hit = memmem (buf + pos, len - pos, "OggS", 4);

        if (hit == NULL)
            break;
        pos = (gsize) (hit - buf);
        g_array_append_val (hits, pos);
        pos++;
    }

    for (guint h = hits->len; h > 0 && pending > 0; h--)
    {
        gsize at = g_array_index (hits, gsize, h - 1);
        guint32 serial;
        VsdOggPage pg;
        int i;

        if (len - at < 27 || rd_le64 (buf + at + 6) == G_MAXUINT64)
            continue;
        serial = rd_le32 (buf + at + 14);
        for (i = 0; i < count && (streams[i].serial != serial || streams[i].have_granule); i++)
            ;
        if (i == count || !vsd_ogg_page (buf, len, at, TRUE, &pg))
            continue;
        streams[i].granule = pg.granule;
        streams[i].have_granule = any = TRUE;
        pending--;
    }
    return any;
}

static gboolean
vsd_probe_ogg (VsdReader *r,
               VsdMedia  *m)
{
    VsdOggStream streams[16] = { { 0 } };
    int count = 0;
    gsize len = (gsize) MIN (r->size, (guint64) 16 * 1024), pos = 0;
    g_autofree guint8 *head = vsd_read_alloc (r, 0, len);
    VsdOggPage pg;

    m->format = "Ogg";
    if (head == NULL)
        return FALSE;
    vsd_ogg_crc_init ();

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

    if (!vsd_ogg_scan_tail (r, 72 * 1024, streams, count))
        vsd_ogg_scan_tail (r, 1024 * 1024, streams, count);

    for (int i = 0; i < count; i++)
        m->seconds = MAX (m->seconds, vsd_ogg_stream_seconds (&streams[i]));
    return TRUE;
}

static gboolean
vsd_probe_flac (VsdReader *r,
                guint64    start,
                VsdMedia  *m)
{
    guint8 p[4 + 4 + 18];
    guint32 rate;
    guint64 samples;

    m->format = "FLAC";

    if (!vsd_read_at (r, start, p, sizeof p) || (p[4] & 0x7f) != 0 || rd_be24 (p + 5) < 18)
        return FALSE;
    rate = ((guint32) p[18] << 12) | ((guint32) p[19] << 4) | (p[20] >> 4);
    samples = ((guint64) (p[21] & 0x0f) << 32) | rd_be32 (p + 22);
    if (rate > 0 && samples > 0)
        m->seconds = (double) samples / rate;
    return TRUE;
}

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
            guint64 play = rd_le64 (p + 40);
            guint64 preroll = rd_le64 (p + 56);

            if (!(rd_le32 (p + 64) & 0x01))
            {
                double s = (double) play / 1e7 - (double) preroll / 1000.0;
                m->seconds = s > 0.0 ? s : (double) play / 1e7;
            }
            have_props = TRUE;
        }
        else if (memcmp (o, ASF_STREAM_PROPERTIES, 16) == 0 && size >= 24 + 62 &&
                 vsd_read_at (r, off + 24, p, 62) && memcmp (p, ASF_VIDEO_MEDIA, 16) == 0)
        {
            vsd_media_add_video (m, rd_le32 (p + 54), rd_le32 (p + 58));
        }
        off += size;
    }
    return have_props;
}

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
    version = (h >> 19) & 3;
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

static guint64
vsd_audio_end (VsdReader *r)
{
    guint8 t[3];
    if (r->size > 128 && vsd_read_at (r, r->size - 128, t, 3) && memcmp (t, "TAG", 3) == 0)
        return r->size - 128;
    return r->size;
}

#define VSD_MPA_WINDOW (64u * 1024u)
#define VSD_MPA_JUNK   (1024u * 1024u)
#define VSD_ADTS_COUNT (1024u * 1024u)
#define VSD_ADTS_CHUNK (192u * 1024u)
#define VSD_ADTS_PARTS 4u

static gsize
vsd_adts_count (const guint8 *b,
                gsize         len,
                guint32       rate,
                gboolean      resync,
                guint64      *bytes,
                guint64      *samples)
{
    guint32 r2, l2, s2;
    gsize p = 0;

    while (resync && p + 7 <= len)
    {
        guint32 ra, la, sa, rb, lb, sb;

        if (b[p] == 0xFF && vsd_adts_parse (b + p, &ra, &la, &sa) && ra == rate && p + la + 7 <= len &&
            vsd_adts_parse (b + p + la, &rb, &lb, &sb) && rb == rate && p + la + lb + 7 <= len &&
            vsd_adts_parse (b + p + la + lb, &r2, &l2, &s2) && r2 == rate)
            break;
        p++;
    }
    while (p + 7 <= len && vsd_adts_parse (b + p, &r2, &l2, &s2) && r2 == rate && p + l2 <= len)
    {
        *bytes += l2;
        *samples += s2;
        p += l2;
    }
    return p;
}

static gboolean
vsd_adts_sample (VsdReader *r,
                 guint64    off,
                 guint32    rate,
                 guint64   *bytes,
                 guint64   *samples)
{
    gsize len = (gsize) MIN ((guint64) VSD_ADTS_CHUNK, r->size - MIN (off, r->size));
    g_autofree guint8 *buf = len > 0 ? vsd_read_alloc (r, off, len) : NULL;

    if (buf == NULL)
        return FALSE;
    vsd_adts_count (buf, len, rate, TRUE, bytes, samples);
    return TRUE;
}

static int
vsd_mpeg_audio_window (VsdReader *r,
                       guint64    start,
                       gsize      want,
                       gsize      search,
                       guint64    audio_end,
                       VsdMedia  *m)
{
    gsize len = (gsize) MIN (r->size - MIN (start, r->size), (guint64) want);
    g_autofree guint8 *buf = vsd_read_alloc (r, start, len);

    if (buf == NULL)
        return -1;
    if (len < want)
        search = len;

    for (gsize pos = 0; pos + 10 <= len && pos < search; pos++)
    {
        guint32 rate, flen, spf;
        VsdMpa f, g, h;

        if (buf[pos] != 0xFF)
            continue;

        if (vsd_adts_parse (buf + pos, &rate, &flen, &spf))
        {
            guint32 r2, l2, s2;
            guint64 bytes = 0, samples = 0, first = start + pos;
            guint64 span = audio_end > first ? audio_end - first : r->size - first;
            gsize clen = (gsize) MIN (span, (guint64) VSD_ADTS_COUNT);
            g_autofree guint8 *cbuf = NULL;
            const guint8 *cb;

            if (pos + flen + 7 <= len && !(vsd_adts_parse (buf + pos + flen, &r2, &l2, &s2) && r2 == rate))
                continue;

            m->format = "AAC ADTS";
            if (span > VSD_ADTS_COUNT)
            {
                for (guint k = 0; k < VSD_ADTS_PARTS; k++)
                {
                    guint64 center = first + span * (2 * k + 1) / (2 * VSD_ADTS_PARTS);

                    vsd_adts_sample (r, center > first + VSD_ADTS_CHUNK / 2 ? center - VSD_ADTS_CHUNK / 2 : first,
                                     rate, &bytes, &samples);
                }
                if (bytes > 0)
                {
                    m->seconds = (double) span * ((double) samples / (double) bytes) / rate;
                    return 1;
                }
            }

            if (pos + clen <= len)
            {
                cb = buf + pos;
            }
            else
            {
                gsize have = len - pos;

                cbuf = g_malloc (clen);
                memcpy (cbuf, buf + pos, have);
                if (!vsd_read_at (r, first + have, cbuf + have, clen - have))
                    return -1;
                cb = cbuf;
            }

            vsd_adts_count (cb, clen, rate, FALSE, &bytes, &samples);
            if (bytes == 0)
                return -1;
            m->seconds = span > VSD_ADTS_COUNT ? (double) span * ((double) samples / (double) bytes) / rate
                                               : (double) samples / rate;
            return 1;
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
            if (pos + f.xing_offset + 12 <= len && (memcmp (x, "Xing", 4) == 0 || memcmp (x, "Info", 4) == 0) &&
                (rd_be32 (x + 4) & 0x01))
                m->seconds = (double) rd_be32 (x + 8) * f.samples / f.sample_rate;
            else if (pos + 36 + 18 <= len && memcmp (v, "VBRI", 4) == 0)
                m->seconds = (double) rd_be32 (v + 14) * f.samples / f.sample_rate;
            else if (f.bitrate > 0 && audio_end > start + pos)
                m->seconds = (double) (audio_end - start - pos) * 8.0 / f.bitrate;
            return 1;
        }
    }
    return 0;
}

static gboolean
vsd_probe_mpeg_audio (VsdReader *r,
                      guint64    start,
                      guint      hints,
                      VsdMedia  *m)
{
    guint64 audio_end = vsd_audio_end (r);
    int res = vsd_mpeg_audio_window (r, start, VSD_MPA_WINDOW, VSD_MPA_WINDOW - 8192, audio_end, m);

    if (res == 0 && (hints & VSD_HINT_MPEG_AUDIO || start > 0) &&
        r->size - MIN (start, r->size) > VSD_MPA_WINDOW)
        res = vsd_mpeg_audio_window (r, start, VSD_MPA_JUNK, 128 * 1024, audio_end, m);
    return res > 0;
}

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

static gboolean
vsd_probe_reader (VsdReader *r,
                  guint      hints,
                  VsdMedia  *m)
{
    guint8 head[64];
    gsize n;
    guint64 start;

    n = vsd_read_some (r, 0, head, sizeof head);
    if (n < 16)
        return FALSE;

    if (vsd_bmff_known_box (rd_be32 (head + 4)))
        return vsd_probe_bmff (r, m);
    if (rd_be32 (head) == MKV_EBML)
        return vsd_probe_matroska (r, m);
    if ((rd_be32 (head) == RIFF_RIFF || rd_be32 (head) == RIFF_RF64 || rd_be32 (head) == RIFF_BW64) &&
        rd_be32 (head + 8) == RIFF_WAVE)
        return vsd_probe_wav (r, head, m);
    if (rd_be32 (head) == RIFF_RIFF && rd_be32 (head + 8) == RIFF_AVI)
        return vsd_probe_avi (r, m);
    if (memcmp (head, "OggS", 4) == 0)
        return vsd_probe_ogg (r, m);
    if (memcmp (head, ASF_HEADER, 16) == 0)
        return vsd_probe_asf (r, m);

    start = vsd_skip_id3v2 (r);
    n = vsd_read_some (r, start, head, 4);
    if (n == 4 && memcmp (head, "fLaC", 4) == 0)
        return vsd_probe_flac (r, start, m);
    if ((n >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) || start > 0 || (hints & VSD_HINT_MPEG_AUDIO))
        return vsd_probe_mpeg_audio (r, start, hints, m);
    return FALSE;
}

static gboolean
vsd_probe (GFile        *location,
           guint         hints,
           GCancellable *cancellable,
           VsdMedia     *m)
{
    g_autoptr (GFileInputStream) stream = NULL;
    VsdReader *r = g_new0 (VsdReader, 1);
    const char *path = g_file_peek_path (location);
    gboolean ok = FALSE;

    memset (m, 0, sizeof *m);
    r->fd = -1;
    r->cancellable = cancellable;

    if (path != NULL)
    {
        struct stat st;

        r->fd = open (path, O_RDONLY | O_CLOEXEC | O_NOCTTY | O_NONBLOCK);
        if (r->fd >= 0 && (fstat (r->fd, &st) != 0 || !S_ISREG (st.st_mode)))
            goto out;
        if (r->fd >= 0)
        {
            r->size = (guint64) st.st_size;
#ifdef POSIX_FADV_RANDOM
            posix_fadvise (r->fd, 0, 0, POSIX_FADV_RANDOM);
#endif
        }
    }
    if (r->fd < 0)
    {
        g_autoptr (GFileInfo) info = NULL;

        stream = g_file_read (location, cancellable, NULL);
        if (stream == NULL || !g_seekable_can_seek (G_SEEKABLE (stream)))
            goto out;
        r->in = G_INPUT_STREAM (stream);
        info = g_file_input_stream_query_info (stream, G_FILE_ATTRIBUTE_STANDARD_SIZE, cancellable, NULL);
        if (info != NULL && g_file_info_has_attribute (info, G_FILE_ATTRIBUTE_STANDARD_SIZE))
            r->size = (guint64) g_file_info_get_size (info);
        else if (g_seekable_seek (G_SEEKABLE (stream), 0, G_SEEK_END, cancellable, NULL))
            r->size = (guint64) g_seekable_tell (G_SEEKABLE (stream));
    }

    ok = vsd_probe_reader (r, hints, m);

out:
    if (r->fd >= 0)
        close (r->fd);
    g_free (r);
    return ok;
}

#ifndef VSD_THUMBNAILER
#define VSD_CELL 32

static void
vsd_format_duration (double seconds,
                     char   out[VSD_CELL])
{
    char tmp[VSD_CELL];
    guint64 s;

    out[0] = '\0';
    if (seconds <= 0.0 || seconds > VSD_MAX_SECONDS)
        return;
    s = (guint64) (seconds + 0.5);
    if (s >= 3600)
        g_snprintf (tmp, sizeof tmp, "%" G_GUINT64_FORMAT ":%02u:%02u",
                    s / 3600, (guint) (s / 60 % 60), (guint) (s % 60));
    else
        g_snprintf (tmp, sizeof tmp, "%u:%02u", (guint) (s / 60), (guint) (s % 60));
    g_snprintf (out, VSD_CELL, "%8s", tmp);
}

static void
vsd_format_pixels (guint32 px,
                   char    out[VSD_CELL])
{
    out[0] = '\0';
    if (px)
        g_snprintf (out, VSD_CELL, "%5u", px);
}

typedef struct
{
    GObject parent_instance;
} VideoSizeDurationProvider;

typedef struct
{
    GObjectClass parent_class;
} VideoSizeDurationProviderClass;

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
static void vsd_menu_provider_iface_init (NautilusMenuProviderInterface *iface);

G_DEFINE_DYNAMIC_TYPE_EXTENDED (VideoSizeDurationProvider, video_size_duration_provider, G_TYPE_OBJECT, 0,
                                G_IMPLEMENT_INTERFACE_DYNAMIC (NAUTILUS_TYPE_COLUMN_PROVIDER,
                                                               vsd_column_provider_iface_init)
                                G_IMPLEMENT_INTERFACE_DYNAMIC (NAUTILUS_TYPE_INFO_PROVIDER,
                                                               vsd_info_provider_iface_init)
                                G_IMPLEMENT_INTERFACE_DYNAMIC (NAUTILUS_TYPE_MENU_PROVIDER,
                                                               vsd_menu_provider_iface_init))

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
                  "default-sort-order", 1,
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
    "mp4", "m4v", "m4a", "m4b", "mov", "3gp", "3g2",
    "mkv", "mka", "webm", "avi", "wav", "ogg", "oga", "ogv", "opus", "spx",
    "flac", "wma", "wmv", "asf", "mp3", "mp2", "aac", NULL
};

static gboolean
vsd_is_candidate (NautilusFileInfo *file,
                  guint            *hints)
{
    g_autofree char *mime = NULL;
    g_autofree char *name = NULL;
    const char *dot;
    gboolean known_suffix = FALSE;

    *hints = 0;
    if (nautilus_file_info_get_file_type (file) != G_FILE_TYPE_REGULAR)
        return FALSE;

    name = nautilus_file_info_get_name (file);
    dot = name != NULL ? strrchr (name, '.') : NULL;
    if (dot != NULL && dot[1] != '\0' && strlen (dot + 1) <= 4)
    {
        char ext[5];
        gsize n = 0;

        for (const char *c = dot + 1; *c != '\0'; c++)
            ext[n++] = g_ascii_tolower (*c);
        ext[n] = '\0';
        for (const char *const *suffix = vsd_suffixes; *suffix != NULL && !known_suffix; suffix++)
            known_suffix = strcmp (ext, *suffix) == 0;
        if (known_suffix && (strcmp (ext, "mp3") == 0 || strcmp (ext, "mp2") == 0 || strcmp (ext, "aac") == 0))
            *hints |= VSD_HINT_MPEG_AUDIO;
    }

    mime = nautilus_file_info_get_mime_type (file);
    if (mime != NULL && (g_str_equal (mime, "audio/mpeg") || g_str_has_prefix (mime, "audio/aac") ||
                         g_str_has_prefix (mime, "audio/x-aac") || g_str_equal (mime, "audio/x-hx-aac-adts")))
        *hints |= VSD_HINT_MPEG_AUDIO;

    return known_suffix ||
           (mime != NULL && (g_str_has_prefix (mime, "video/") || g_str_has_prefix (mime, "audio/") ||
                             g_str_equal (mime, "application/ogg") ||
                             g_str_equal (mime, "application/mp4") ||
                             g_str_equal (mime, "application/x-matroska") ||
                             g_str_equal (mime, "application/vnd.ms-asf")));
}

static void
vsd_set_attributes (NautilusFileInfo *file,
                    const VsdMedia   *m)
{
    char duration[VSD_CELL], width[VSD_CELL], height[VSD_CELL];

    vsd_format_duration (m ? m->seconds : 0.0, duration);
    vsd_format_pixels (m ? m->width : 0, width);
    vsd_format_pixels (m ? m->height : 0, height);

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

    g_cancellable_cancel (request->cancellable);
}

static void
vsd_info_provider_iface_init (NautilusInfoProviderInterface *iface)
{
    iface->update_file_info = vsd_update_file_info;
    iface->cancel_update = vsd_cancel_update;
}

typedef struct
{
    const char *attribute;
    gboolean    reversed;
} VsdSortChoice;

static const VsdSortChoice vsd_sort_choices[6] = {
    { VSD_ATTR_DURATION, TRUE }, { VSD_ATTR_DURATION, FALSE },
    { VSD_ATTR_WIDTH, TRUE },    { VSD_ATTR_WIDTH, FALSE },
    { VSD_ATTR_HEIGHT, TRUE },   { VSD_ATTR_HEIGHT, FALSE },
};

static gpointer
vsd_gtk_symbol (const char *name)
{
    static GModule *self = NULL;
    static gsize once = 0;
    gpointer sym = NULL;

    if (g_once_init_enter (&once))
    {
        self = g_module_open (NULL, 0);
        g_once_init_leave (&once, 1);
    }
    if (self == NULL || !g_module_symbol (self, name, &sym))
        return NULL;
    return sym;
}

typedef gboolean (*VsdActivateActionFn) (gpointer    widget,
                                         const char *name,
                                         GVariant   *args);
typedef gpointer (*VsdWidgetFn) (gpointer widget);
typedef GList   *(*VsdAppWindowsFn) (gpointer app);

static VsdActivateActionFn
vsd_gtk_activate_action (void)
{
    return (VsdActivateActionFn) vsd_gtk_symbol ("gtk_widget_activate_action_variant");
}

static void
vsd_sort_activate (NautilusMenuItem *item,
                   gpointer          user_data)
{
    const VsdSortChoice *choice = user_data;
    VsdActivateActionFn activate = vsd_gtk_activate_action ();
    GApplication *app = g_application_get_default ();
    g_autoptr (GObject) window = NULL;
    g_autoptr (GVariant) args = NULL;

    (void) item;
    if (activate == NULL || app == NULL ||
        g_object_class_find_property (G_OBJECT_GET_CLASS (app), "active-window") == NULL)
    {
        g_warning ("Nie można zmienić sortowania: brak GTK / sorting unavailable");
        return;
    }
    g_object_get (app, "active-window", &window, NULL);
    if (window == NULL)
        return;

    args = g_variant_ref_sink (g_variant_new ("(sb)", choice->attribute, choice->reversed));
    if (!activate (window, "view.sort", args))
        g_warning ("Akcja view.sort niedostępna / view.sort action not found");
    else
        g_debug ("Sortowanie / sort: %s%s", choice->attribute, choice->reversed ? " (malejąco)" : "");
}

#define VSD_SECTION_ATTR "nvsd-sort-section"

static gboolean vsd_inject_pending = FALSE;

static gboolean
vsd_is_view_menu (GMenuModel *model)
{
    g_autoptr (GMenuModel) section = NULL;

    if (!G_IS_MENU (model) || g_menu_model_get_n_items (model) < 2)
        return FALSE;
    section = g_menu_model_get_item_link (model, 1, G_MENU_LINK_SECTION);
    if (section == NULL)
        return FALSE;
    for (int i = 0; i < g_menu_model_get_n_items (section); i++)
    {
        g_autofree char *action = NULL;

        if (g_menu_model_get_item_attribute (section, i, G_MENU_ATTRIBUTE_ACTION, "s", &action) &&
            g_str_equal (action, "view.sort"))
            return TRUE;
    }
    return FALSE;
}

static gboolean
vsd_has_sort_section (GMenuModel *menu)
{
    for (int i = 0; i < g_menu_model_get_n_items (menu); i++)
    {
        gboolean mine = FALSE;

        if (g_menu_model_get_item_attribute (menu, i, VSD_SECTION_ATTR, "b", &mine) && mine)
            return TRUE;
    }
    return FALSE;
}

static void
vsd_inject_sort_section (GMenu *view_menu)
{
    const VsdStrings *s = vsd_pick_strings ();
    g_autoptr (GMenu) section = NULL;
    g_autoptr (GMenuItem) item = NULL;

    if (vsd_has_sort_section (G_MENU_MODEL (view_menu)))
        return;

    section = g_menu_new ();
    for (int i = 0; i < (int) G_N_ELEMENTS (vsd_sort_choices); i++)
    {
        g_autoptr (GMenuItem) choice = g_menu_item_new (s->sort_items[i], NULL);

        g_menu_item_set_action_and_target_value (choice, "view.sort",
                                                 g_variant_new ("(sb)", vsd_sort_choices[i].attribute,
                                                                vsd_sort_choices[i].reversed));
        g_menu_append_item (section, choice);
    }
    item = g_menu_item_new_section (s->sort_section, G_MENU_MODEL (section));
    g_menu_item_set_attribute (item, VSD_SECTION_ATTR, "b", TRUE);
    g_menu_insert_item (view_menu, 2, item);
    g_debug ("Dodano sekcję do menu „Porządkowanie” / sort section added");
}

typedef struct
{
    VsdWidgetFn first_child;
    VsdWidgetFn next_sibling;
    GType       skip;
    int         budget;
    gpointer    found;
} VsdWalk;

#define VSD_WINDOW_KEY "nvsd-view-menu"

static void
vsd_weak_ref_free (gpointer data)
{
    g_weak_ref_clear (data);
    g_free (data);
}

static gboolean
vsd_window_ready (GObject *window)
{
    GWeakRef *ref = g_object_get_data (window, VSD_WINDOW_KEY);
    g_autoptr (GObject) holder = ref != NULL ? g_weak_ref_get (ref) : NULL;
    g_autoptr (GMenuModel) model = NULL;

    if (holder == NULL)
        return FALSE;
    g_object_get (holder, "menu-model", &model, NULL);
    return model != NULL && vsd_has_sort_section (model);
}

static void
vsd_window_remember (GObject  *window,
                     gpointer  holder)
{
    GWeakRef *ref = g_new0 (GWeakRef, 1);

    g_weak_ref_init (ref, holder);
    g_object_set_data_full (window, VSD_WINDOW_KEY, ref, vsd_weak_ref_free);
}

static void
vsd_walk_widget (VsdWalk  *walk,
                 gpointer  widget,
                 int       depth)
{
    GParamSpec *pspec;

    if (widget == NULL || walk->budget-- <= 0 || depth > 48)
        return;
    if (walk->skip != 0 && g_type_is_a (G_OBJECT_TYPE (widget), walk->skip))
        return;

    pspec = g_object_class_find_property (G_OBJECT_GET_CLASS (widget), "menu-model");
    if (pspec != NULL && g_type_is_a (pspec->value_type, G_TYPE_MENU_MODEL))
    {
        g_autoptr (GMenuModel) model = NULL;

        g_object_get (widget, "menu-model", &model, NULL);
        if (model != NULL && vsd_is_view_menu (model))
        {
            vsd_inject_sort_section (G_MENU (model));
            walk->found = widget;
        }
    }
    for (gpointer child = walk->first_child (widget); child != NULL; child = walk->next_sibling (child))
        vsd_walk_widget (walk, child, depth + 1);
}

static gboolean
vsd_inject_idle (gpointer user_data)
{
    GApplication *app = g_application_get_default ();
    VsdAppWindowsFn get_windows = (VsdAppWindowsFn) vsd_gtk_symbol ("gtk_application_get_windows");
    GType gtk_app = g_type_from_name ("GtkApplication");
    VsdWalk walk = {
        (VsdWidgetFn) vsd_gtk_symbol ("gtk_widget_get_first_child"),
        (VsdWidgetFn) vsd_gtk_symbol ("gtk_widget_get_next_sibling"),
        g_type_from_name ("GtkListBase"),
        0,
        NULL,
    };

    (void) user_data;
    vsd_inject_pending = FALSE;
    if (app == NULL || gtk_app == 0 || !g_type_is_a (G_OBJECT_TYPE (app), gtk_app) ||
        get_windows == NULL || walk.first_child == NULL || walk.next_sibling == NULL)
        return G_SOURCE_REMOVE;

    for (GList *l = get_windows (app); l != NULL; l = l->next)
    {
        if (vsd_window_ready (l->data))
            continue;
        walk.budget = 20000;
        walk.found = NULL;
        vsd_walk_widget (&walk, l->data, 0);
        if (walk.found != NULL)
            vsd_window_remember (l->data, walk.found);
    }
    return G_SOURCE_REMOVE;
}

static void
vsd_schedule_injection (void)
{
    if (vsd_inject_pending)
        return;
    vsd_inject_pending = TRUE;
    g_idle_add (vsd_inject_idle, NULL);
}

static GList *
vsd_get_background_items (NautilusMenuProvider *provider,
                          NautilusFileInfo     *current_folder)
{
    const VsdStrings *s = vsd_pick_strings ();
    NautilusMenuItem *parent;
    NautilusMenu *menu;

    (void) provider;
    (void) current_folder;
    vsd_schedule_injection ();

    parent = nautilus_menu_item_new ("VideoSizeDuration::sort", s->sort_menu, s->sort_tip, NULL);
    menu = nautilus_menu_new ();
    for (int i = 0; i < (int) G_N_ELEMENTS (vsd_sort_choices); i++)
    {
        char name[40];
        NautilusMenuItem *item;

        g_snprintf (name, sizeof name, "VideoSizeDuration::sort-%d", i);
        item = nautilus_menu_item_new (name, s->sort_items[i], s->sort_tip, NULL);

        g_signal_connect (item, "activate", G_CALLBACK (vsd_sort_activate),
                          (gpointer) &vsd_sort_choices[i]);
        nautilus_menu_append_item (menu, item);
        g_object_unref (item);
    }
    nautilus_menu_item_set_submenu (parent, menu);
    g_object_unref (menu);
    return g_list_append (NULL, parent);
}

static GList *
vsd_get_file_items (NautilusMenuProvider *provider,
                    GList                *files)
{
    (void) provider;
    (void) files;
    return NULL;
}

static void
vsd_menu_provider_iface_init (NautilusMenuProviderInterface *iface)
{
    iface->get_file_items = vsd_get_file_items;
    iface->get_background_items = vsd_get_background_items;
}

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
#endif

#ifdef VSD_THUMBNAILER

#include <cairo.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <unistd.h>
#include <glib/gstdio.h>

#define VSD_THUMB_NAME     "nautilus-video-size-duration-thumbnailer"
#define VSD_THUMB_FILE_PFX "nautilus-video-size-duration"
#define VSD_THUMB_GUARD    "NVSD_THUMBNAILER_ACTIVE"

static char *
vsd_format_human (double seconds)
{
    guint64 s;

    if (seconds <= 0.0 || seconds > VSD_MAX_SECONDS)
        return NULL;
    s = (guint64) (seconds + 0.5);
    if (s >= 3600)
        return g_strdup_printf ("%" G_GUINT64_FORMAT "h %um %us",
                                s / 3600, (guint) (s / 60 % 60), (guint) (s % 60));
    if (s >= 60)
        return g_strdup_printf ("%um %us", (guint) (s / 60), (guint) (s % 60));
    return g_strdup_printf ("%us", (guint) s);
}

static double
vsd_glyph_path (cairo_t *cr,
                char     c)
{
    switch (c)
    {
        case '0':
            cairo_new_sub_path (cr);
            cairo_arc (cr, 3, 3, 3, G_PI, 2 * G_PI);
            cairo_arc (cr, 3, 7, 3, 0, G_PI);
            cairo_close_path (cr);
            return 6;
        case '1':
            cairo_move_to (cr, 1.0, 2.4);
            cairo_line_to (cr, 3.6, 0);
            cairo_line_to (cr, 3.6, 10);
            return 6;
        case '2':
            cairo_new_sub_path (cr);
            cairo_arc (cr, 3, 3, 3, G_PI, G_PI * 2.2);
            cairo_line_to (cr, 0, 10);
            cairo_line_to (cr, 6, 10);
            return 6;
        case '3':
            cairo_new_sub_path (cr);
            cairo_arc (cr, 3, 2.5, 2.5, G_PI * 1.1, G_PI * 2.5);
            cairo_arc (cr, 3, 7.5, 2.5, -G_PI * 0.5, G_PI * 0.9);
            return 6;
        case '4':
            cairo_move_to (cr, 4.4, 10);
            cairo_line_to (cr, 4.4, 0);
            cairo_line_to (cr, 0, 6.8);
            cairo_line_to (cr, 6, 6.8);
            return 6;
        case '5':
            cairo_move_to (cr, 5.6, 0);
            cairo_line_to (cr, 1.0, 0);
            cairo_line_to (cr, 0.8, 4.5);
            cairo_arc (cr, 3, 6.9, 3.1, -2.3, 2.6);
            return 6;
        case '6':
            cairo_move_to (cr, 4.6, 0);
            cairo_line_to (cr, 0.43, 5.45);
            cairo_new_sub_path (cr);
            cairo_arc (cr, 3, 7, 3, 0, 2 * G_PI);
            return 6;
        case '7':
            cairo_move_to (cr, 0, 0);
            cairo_line_to (cr, 6, 0);
            cairo_line_to (cr, 1.8, 10);
            return 6;
        case '8':
            cairo_new_sub_path (cr);
            cairo_arc (cr, 3, 2.4, 2.4, 0, 2 * G_PI);
            cairo_new_sub_path (cr);
            cairo_arc (cr, 3, 7.3, 2.7, 0, 2 * G_PI);
            return 6;
        case '9':
            cairo_new_sub_path (cr);
            cairo_arc (cr, 3, 3, 3, 0, 2 * G_PI);
            cairo_move_to (cr, 5.57, 4.55);
            cairo_line_to (cr, 1.4, 10);
            return 6;
        case 'h':
            cairo_move_to (cr, 0.6, 0);
            cairo_line_to (cr, 0.6, 10);
            cairo_move_to (cr, 0.6, 6.0);
            cairo_arc (cr, 2.85, 6.0, 2.25, G_PI, 2 * G_PI);
            cairo_line_to (cr, 5.1, 10);
            return 5.7;
        case 'm':
            cairo_move_to (cr, 0.6, 3.8);
            cairo_line_to (cr, 0.6, 10);
            cairo_move_to (cr, 0.6, 5.8);
            cairo_arc (cr, 2.6, 5.8, 2.0, G_PI, 2 * G_PI);
            cairo_line_to (cr, 4.6, 10);
            cairo_move_to (cr, 4.6, 5.8);
            cairo_arc (cr, 6.6, 5.8, 2.0, G_PI, 2 * G_PI);
            cairo_line_to (cr, 8.6, 10);
            return 9.2;
        case 's':
            cairo_new_sub_path (cr);
            cairo_arc_negative (cr, 2.6, 5.4, 1.6, -0.35, -G_PI * 1.5);
            cairo_arc (cr, 2.6, 8.5, 1.5, -G_PI * 0.5, G_PI - 0.45);
            return 4.6;
        case ' ':
            return 2.8;
        default:
            return 0;
    }
}

#define VSD_GLYPH_TRACKING 1.9
#define VSD_GLYPH_STROKE   1.45

static double
vsd_text_width_units (const char *text)
{
    double w = 0.0;
    cairo_surface_t *dummy = cairo_image_surface_create (CAIRO_FORMAT_A8, 1, 1);
    cairo_t *cr = cairo_create (dummy);

    for (const char *p = text; *p; p++)
    {
        w += vsd_glyph_path (cr, *p);
        cairo_new_path (cr);
        if (p[1] != '\0')
            w += VSD_GLYPH_TRACKING;
    }
    cairo_destroy (cr);
    cairo_surface_destroy (dummy);
    return w;
}

static void
vsd_draw_text (cairo_t    *cr,
               const char *text,
               double      x,
               double      y,
               double      k)
{
    for (const char *p = text; *p; p++)
    {
        double adv;

        cairo_save (cr);
        cairo_translate (cr, x, y);
        cairo_scale (cr, k, k);
        cairo_new_path (cr);
        adv = vsd_glyph_path (cr, *p);
        cairo_restore (cr);
        cairo_stroke (cr);
        x += (adv + VSD_GLYPH_TRACKING) * k;
    }
}

static void
vsd_draw_icon (cairo_t  *cr,
               gboolean  video,
               double    x,
               double    y,
               double    k)
{
    cairo_save (cr);
    cairo_translate (cr, x, y);
    cairo_scale (cr, k, k);
    cairo_new_path (cr);
    if (video)
    {
        cairo_move_to (cr, 0.6, 0.6);
        cairo_line_to (cr, 8.4, 5.0);
        cairo_line_to (cr, 0.6, 9.4);
        cairo_close_path (cr);
        cairo_restore (cr);
        cairo_fill_preserve (cr);
        cairo_stroke (cr);
        return;
    }
    cairo_save (cr);
    cairo_translate (cr, 2.7, 8.1);
    cairo_rotate (cr, -0.35);
    cairo_scale (cr, 2.7, 1.9);
    cairo_arc (cr, 0, 0, 1, 0, 2 * G_PI);
    cairo_restore (cr);
    cairo_restore (cr);
    cairo_fill (cr);

    cairo_save (cr);
    cairo_translate (cr, x, y);
    cairo_scale (cr, k, k);
    cairo_move_to (cr, 5.1, 7.8);
    cairo_line_to (cr, 5.1, 0.4);
    cairo_curve_to (cr, 6.4, 1.8, 8.8, 2.4, 7.8, 5.6);
    cairo_restore (cr);
    cairo_stroke (cr);
}

static void
vsd_rounded_rect (cairo_t *cr,
                  double   x,
                  double   y,
                  double   w,
                  double   h,
                  double   r)
{
    r = MIN (r, MIN (w, h) / 2);
    cairo_new_sub_path (cr);
    cairo_arc (cr, x + w - r, y + r, r, -G_PI / 2, 0);
    cairo_arc (cr, x + w - r, y + h - r, r, 0, G_PI / 2);
    cairo_arc (cr, x + r, y + h - r, r, G_PI / 2, G_PI);
    cairo_arc (cr, x + r, y + r, r, G_PI, 3 * G_PI / 2);
    cairo_close_path (cr);
}

static void
vsd_draw_badge (cairo_t    *cr,
                int         w,
                int         h,
                const char *label,
                gboolean    video)
{
    double text_units = vsd_text_width_units (label);
    double bh = 12.0 + 0.075 * MAX (w, h);
    double k, pad, gap, icon_w, bw, margin, border;

    bh = MIN (bh, 0.30 * h);
    for (int i = 0; i < 2; i++)
    {
        k = bh * 0.50 / 10.0;
        pad = bh * 0.32;
        gap = bh * 0.24;
        icon_w = 9.0 * k;
        bw = pad + icon_w + gap + text_units * k + pad;
        margin = MAX (2.0, bh * 0.28);
        if (bw + 2 * margin <= w)
            break;
        bh *= (w - 2 * margin) / (bw + 2 * margin) * 0.98;
    }
    if (bh < 10.0)
        return;

    k = bh * 0.50 / 10.0;
    pad = bh * 0.32;
    gap = bh * 0.24;
    icon_w = 9.0 * k;
    bw = pad + icon_w + gap + text_units * k + pad;
    margin = MAX (2.0, bh * 0.28);
    border = MAX (1.0, bh * 0.055);

    cairo_save (cr);
    vsd_rounded_rect (cr, margin, margin, bw, bh, bh * 0.24);
    cairo_set_source_rgba (cr, 0, 0, 0, 0.72);
    cairo_fill (cr);
    vsd_rounded_rect (cr, margin + border / 2, margin + border / 2, bw - border, bh - border,
                      bh * 0.24 - border / 2);
    cairo_set_source_rgba (cr, 1, 1, 1, 0.88);
    cairo_set_line_width (cr, border);
    cairo_stroke (cr);

    cairo_set_source_rgb (cr, 1, 1, 1);
    cairo_set_line_cap (cr, CAIRO_LINE_CAP_ROUND);
    cairo_set_line_join (cr, CAIRO_LINE_JOIN_ROUND);
    cairo_set_line_width (cr, VSD_GLYPH_STROKE * k);
    vsd_draw_icon (cr, video, margin + pad, margin + (bh - 10 * k) / 2, k);
    vsd_draw_text (cr, label, margin + pad + icon_w + gap, margin + (bh - 10 * k) / 2, k);
    cairo_restore (cr);
}

static void
vsd_nib_stroke (cairo_t *cr,
                void   (*path) (cairo_t *),
                double   nib,
                double   angle,
                double   thin)
{
    const int passes = 14;

    for (int i = 0; i <= passes; i++)
    {
        double t = (i / (double) passes - 0.5) * nib;

        cairo_save (cr);
        cairo_translate (cr, t * cos (angle), t * sin (angle));
        cairo_new_path (cr);
        path (cr);
        cairo_restore (cr);
        cairo_set_line_width (cr, thin);
        cairo_stroke (cr);
    }
}

static void
vsd_g_clef_path (cairo_t *cr)
{
    cairo_move_to (cr, 1.42, 3.02);
    cairo_curve_to (cr, 1.42, 3.40, 1.05, 3.52, 0.82, 3.30);
    cairo_curve_to (cr, 0.52, 3.02, 0.62, 2.45, 1.05, 2.22);
    cairo_curve_to (cr, 1.62, 1.95, 2.28, 2.35, 2.25, 3.05);
    cairo_curve_to (cr, 2.22, 3.80, 1.55, 4.22, 1.02, 4.12);
    cairo_curve_to (cr, 0.35, 4.00, -0.05, 3.40, 0.05, 2.70);
    cairo_curve_to (cr, 0.18, 1.85, 0.95, 1.30, 1.40, 0.72);
    cairo_curve_to (cr, 1.85, 0.12, 2.02, -0.75, 1.72, -1.45);
    cairo_curve_to (cr, 1.55, -1.85, 1.20, -1.80, 1.05, -1.30);
    cairo_curve_to (cr, 0.88, -0.75, 1.05, 0.40, 1.22, 1.60);
    cairo_line_to (cr, 1.62, 4.85);
    cairo_curve_to (cr, 1.70, 5.45, 1.35, 5.80, 0.95, 5.70);
    cairo_curve_to (cr, 0.72, 5.64, 0.62, 5.48, 0.66, 5.32);
}

static void
vsd_notehead (cairo_t *cr,
              double   x,
              double   y,
              double   s)
{
    cairo_save (cr);
    cairo_translate (cr, x, y);
    cairo_rotate (cr, -0.36);
    cairo_scale (cr, 0.60 * s, 0.43 * s);
    cairo_new_sub_path (cr);
    cairo_arc (cr, 0, 0, 1, 0, 2 * G_PI);
    cairo_restore (cr);
    cairo_fill (cr);
}

static void
vsd_time_digit4 (cairo_t *cr,
                 double   x,
                 double   y,
                 double   s)
{
    cairo_save (cr);
    cairo_translate (cr, x, y);
    cairo_scale (cr, s, s);
    cairo_move_to (cr, 0.92, 0.00);
    cairo_line_to (cr, 1.30, 0.00);
    cairo_line_to (cr, 0.36, 1.30);
    cairo_line_to (cr, 1.10, 1.30);
    cairo_line_to (cr, 1.10, 0.62);
    cairo_line_to (cr, 1.42, 0.40);
    cairo_line_to (cr, 1.42, 1.30);
    cairo_line_to (cr, 1.62, 1.30);
    cairo_line_to (cr, 1.62, 1.50);
    cairo_line_to (cr, 1.42, 1.50);
    cairo_line_to (cr, 1.42, 1.80);
    cairo_curve_to (cr, 1.42, 1.92, 1.52, 1.95, 1.64, 1.96);
    cairo_line_to (cr, 1.64, 2.00);
    cairo_line_to (cr, 0.86, 2.00);
    cairo_line_to (cr, 0.86, 1.96);
    cairo_curve_to (cr, 1.00, 1.95, 1.10, 1.92, 1.10, 1.80);
    cairo_line_to (cr, 1.10, 1.50);
    cairo_line_to (cr, 0.05, 1.50);
    cairo_line_to (cr, 0.05, 1.36);
    cairo_close_path (cr);
    cairo_restore (cr);
    cairo_fill (cr);
}

typedef enum
{
    VSD_CARD_CLASSIC,
    VSD_CARD_MP3,
    VSD_CARD_WAV,
    VSD_CARD_FLAC,
    VSD_CARD_OGG,
    VSD_CARD_AAC,
} VsdCard;

typedef enum
{
    VSD_CLEF_TREBLE,
    VSD_CLEF_BASS,
    VSD_CLEF_DRUMS,
} VsdClef;

#define VSD_NO_HEAD      127
#define VSD_COL_STACCATO 1u
#define VSD_COL_BAR      2u
#define VSD_COL_SYSTEM   4u
#define VSD_COL_TRIPLET  8u
#define VSD_COL_SPLIT    16u
#define VSD_ACC_SHARP    1
#define VSD_ACC_NATURAL  2
#define VSD_MAX_SYSTEMS  4

typedef struct
{
    gint8  head;
    guint8 dur;
    guint8 beam;
    guint8 bits;
    guint8 acc;
} VsdCol;

typedef struct
{
    double        center[3];
    double        edge[3];
    double        frame[3];
    VsdClef       clef;
    int           lines;
    int           sharps;
    int           beats;
    const VsdCol *cols;
    guint         n_cols;
} VsdScore;

static void
vsd_draw_paper (cairo_t      *cr,
                int           size,
                const double  center[3],
                const double  edge[3],
                const double  frame[3])
{
    cairo_pattern_t *paper = cairo_pattern_create_radial (size * 0.5, size * 0.45, size * 0.1,
                                                          size * 0.5, size * 0.5, size * 0.78);

    cairo_pattern_add_color_stop_rgb (paper, 0, center[0], center[1], center[2]);
    cairo_pattern_add_color_stop_rgb (paper, 1, edge[0], edge[1], edge[2]);
    cairo_rectangle (cr, 0, 0, size, size);
    cairo_set_source (cr, paper);
    cairo_fill (cr);
    cairo_pattern_destroy (paper);

    cairo_set_source_rgba (cr, frame[0], frame[1], frame[2], 0.55);
    cairo_set_line_width (cr, MAX (1.0, size * 0.006));
    cairo_rectangle (cr, size * 0.045, size * 0.045, size * 0.91, size * 0.91);
    cairo_stroke (cr);
    cairo_set_line_width (cr, MAX (0.6, size * 0.0025));
    cairo_rectangle (cr, size * 0.065, size * 0.065, size * 0.87, size * 0.87);
    cairo_stroke (cr);
}

static void
vsd_draw_staff (cairo_t *cr,
                double   left,
                double   right,
                double   top,
                double   sp,
                int      lines)
{
    cairo_set_source_rgb (cr, 0.12, 0.09, 0.06);
    cairo_set_line_cap (cr, CAIRO_LINE_CAP_BUTT);
    cairo_set_line_width (cr, MAX (0.8, sp * 0.075));
    for (int i = 0; i < 5; i++)
    {
        if (lines == 1 && i != 2)
            continue;
        cairo_move_to (cr, left, top + i * sp);
        cairo_line_to (cr, right, top + i * sp);
    }
    cairo_stroke (cr);
}

static void
vsd_f_clef_path (cairo_t *cr)
{
    cairo_move_to (cr, 0.16, 0.92);
    cairo_curve_to (cr, 0.10, 0.30, 0.62, -0.06, 1.18, -0.04);
    cairo_curve_to (cr, 1.86, -0.02, 2.24, 0.48, 2.22, 1.12);
    cairo_curve_to (cr, 2.18, 2.06, 1.32, 2.86, 0.10, 3.42);
}

static void
vsd_draw_clef (cairo_t *cr,
               VsdClef  clef,
               double   x,
               double   top,
               double   sp)
{
    cairo_save (cr);
    cairo_translate (cr, x, top);
    cairo_scale (cr, sp, sp);
    cairo_set_line_cap (cr, CAIRO_LINE_CAP_ROUND);
    cairo_set_line_join (cr, CAIRO_LINE_JOIN_ROUND);
    if (clef == VSD_CLEF_TREBLE)
    {
        vsd_nib_stroke (cr, vsd_g_clef_path, 0.30, -0.95, 0.07);
        cairo_new_sub_path (cr);
        cairo_arc (cr, 0.83, 5.30, 0.27, 0, 2 * G_PI);
        cairo_fill (cr);
    }
    else if (clef == VSD_CLEF_BASS)
    {
        vsd_nib_stroke (cr, vsd_f_clef_path, 0.30, -0.35, 0.07);
        cairo_new_sub_path (cr);
        cairo_arc (cr, 0.40, 1.00, 0.33, 0, 2 * G_PI);
        cairo_new_sub_path (cr);
        cairo_arc (cr, 2.72, 0.50, 0.16, 0, 2 * G_PI);
        cairo_new_sub_path (cr);
        cairo_arc (cr, 2.72, 1.50, 0.16, 0, 2 * G_PI);
        cairo_fill (cr);
    }
    else
    {
        cairo_rectangle (cr, 0.25, 1.0, 0.36, 2.0);
        cairo_rectangle (cr, 0.95, 1.0, 0.36, 2.0);
        cairo_fill (cr);
    }
    cairo_restore (cr);
}

static void
vsd_draw_music_card (cairo_t *cr,
                     int      size)
{
    static const double center[3] = { 0.973, 0.945, 0.871 };
    static const double edge[3] = { 0.871, 0.800, 0.643 };
    static const double frame[3] = { 0.36, 0.27, 0.16 };
    const double units = 2.7 + 0.4 + 1.7 + 0.8 + (0.8 + 4 * 2.0 + 1.2) + 0.5;

    const double pitch[5] = { 4.0, 3.5, 3.0, 2.5, 1.5 };
    double left = size * 0.11, right = size * 0.89;
    double sp = (right - left) / units;
    double top = size * 0.58 - 2 * sp;
    double x, nx[5], stem = 3.3 * sp, hw = 0.55 * sp, beam1, beam2, bx;

    vsd_draw_paper (cr, size, center, edge, frame);
    vsd_draw_staff (cr, left, right, top, sp, 5);
    vsd_draw_clef (cr, VSD_CLEF_TREBLE, left + 0.15 * sp, top, sp);

    x = left + (2.7 + 0.4) * sp;
    vsd_time_digit4 (cr, x, top, sp);
    vsd_time_digit4 (cr, x, top + 2 * sp, sp);
    x += (1.7 + 0.8) * sp;

    for (int i = 0; i < 5; i++)
    {
        nx[i] = x + (0.8 + i * 2.0) * sp;
        vsd_notehead (cr, nx[i], top + pitch[i] * sp, sp);
    }

    beam1 = top + pitch[1] * sp - stem;
    beam2 = top + pitch[2] * sp - stem;
    cairo_set_line_width (cr, MAX (0.8, sp * 0.09));
    for (int i = 0; i < 4; i++)
    {
        double y1 = i == 1 ? beam1 : i == 2 ? beam2 : top + pitch[i] * sp - stem;

        cairo_move_to (cr, nx[i] + hw - 0.04 * sp, top + pitch[i] * sp - 0.1 * sp);
        cairo_line_to (cr, nx[i] + hw - 0.04 * sp, y1);
    }
    cairo_move_to (cr, nx[4] - hw + 0.04 * sp, top + pitch[4] * sp + 0.1 * sp);
    cairo_line_to (cr, nx[4] - hw + 0.04 * sp, top + pitch[4] * sp + stem);
    cairo_stroke (cr);

    cairo_move_to (cr, nx[1] + hw - 0.09 * sp, beam1);
    cairo_line_to (cr, nx[2] + hw + 0.01 * sp, beam2);
    cairo_line_to (cr, nx[2] + hw + 0.01 * sp, beam2 + 0.48 * sp);
    cairo_line_to (cr, nx[1] + hw - 0.09 * sp, beam1 + 0.48 * sp);
    cairo_close_path (cr);
    cairo_fill (cr);

    cairo_save (cr);
    cairo_translate (cr, nx[4], top - 0.9 * sp);
    cairo_scale (cr, sp, sp);
    cairo_move_to (cr, -0.95, 0.15);
    cairo_curve_to (cr, -0.85, -0.85, 0.85, -0.85, 0.95, 0.15);
    cairo_curve_to (cr, 0.72, -0.55, -0.72, -0.55, -0.95, 0.15);
    cairo_close_path (cr);
    cairo_new_sub_path (cr);
    cairo_arc (cr, 0, 0.02, 0.15, 0, 2 * G_PI);
    cairo_restore (cr);
    cairo_fill (cr);

    bx = right - 0.25 * sp;
    cairo_rectangle (cr, bx - 0.05 * sp, top, 0.25 * sp, 4 * sp);
    cairo_fill (cr);
    cairo_move_to (cr, bx - 0.45 * sp, top);
    cairo_line_to (cr, bx - 0.45 * sp, top + 4 * sp);
    cairo_stroke (cr);
}

static void
vsd_time_digit2 (cairo_t *cr,
                 double   x,
                 double   y,
                 double   s)
{
    cairo_save (cr);
    cairo_translate (cr, x, y);
    cairo_scale (cr, s, s);
    cairo_move_to (cr, 0.12, 2.00);
    cairo_line_to (cr, 1.52, 2.00);
    cairo_line_to (cr, 1.60, 1.42);
    cairo_line_to (cr, 1.52, 1.42);
    cairo_curve_to (cr, 1.46, 1.58, 1.38, 1.64, 1.18, 1.64);
    cairo_line_to (cr, 0.58, 1.64);
    cairo_curve_to (cr, 1.02, 1.30, 1.50, 1.00, 1.50, 0.54);
    cairo_curve_to (cr, 1.50, 0.18, 1.18, 0.00, 0.80, 0.00);
    cairo_curve_to (cr, 0.40, 0.00, 0.12, 0.20, 0.12, 0.48);
    cairo_curve_to (cr, 0.12, 0.68, 0.26, 0.80, 0.42, 0.80);
    cairo_curve_to (cr, 0.58, 0.80, 0.70, 0.68, 0.70, 0.54);
    cairo_curve_to (cr, 0.70, 0.40, 0.60, 0.33, 0.50, 0.30);
    cairo_curve_to (cr, 0.58, 0.18, 0.70, 0.12, 0.82, 0.12);
    cairo_curve_to (cr, 1.04, 0.12, 1.14, 0.32, 1.14, 0.58);
    cairo_curve_to (cr, 1.14, 1.02, 0.76, 1.42, 0.12, 1.94);
    cairo_close_path (cr);
    cairo_restore (cr);
    cairo_fill (cr);
}

static void
vsd_time_digit3 (cairo_t *cr,
                 double   x,
                 double   y,
                 double   s)
{
    cairo_save (cr);
    cairo_translate (cr, x, y);
    cairo_scale (cr, s, s);
    cairo_move_to (cr, 0.18, 0.40);
    cairo_curve_to (cr, 0.18, 0.15, 0.45, 0.00, 0.78, 0.00);
    cairo_curve_to (cr, 1.15, 0.00, 1.38, 0.20, 1.38, 0.48);
    cairo_curve_to (cr, 1.38, 0.72, 1.18, 0.88, 0.92, 0.95);
    cairo_curve_to (cr, 1.25, 1.00, 1.48, 1.22, 1.48, 1.48);
    cairo_curve_to (cr, 1.48, 1.82, 1.18, 2.00, 0.75, 2.00);
    cairo_curve_to (cr, 0.35, 2.00, 0.10, 1.85, 0.10, 1.58);
    cairo_curve_to (cr, 0.10, 1.40, 0.23, 1.28, 0.40, 1.28);
    cairo_curve_to (cr, 0.56, 1.28, 0.66, 1.40, 0.66, 1.54);
    cairo_curve_to (cr, 0.66, 1.66, 0.58, 1.74, 0.50, 1.78);
    cairo_curve_to (cr, 0.58, 1.86, 0.68, 1.89, 0.78, 1.89);
    cairo_curve_to (cr, 1.02, 1.89, 1.10, 1.70, 1.10, 1.48);
    cairo_curve_to (cr, 1.10, 1.20, 0.95, 1.02, 0.62, 1.02);
    cairo_line_to (cr, 0.62, 0.92);
    cairo_curve_to (cr, 0.92, 0.92, 1.04, 0.72, 1.04, 0.50);
    cairo_curve_to (cr, 1.04, 0.28, 0.94, 0.11, 0.76, 0.11);
    cairo_curve_to (cr, 0.66, 0.11, 0.58, 0.15, 0.52, 0.22);
    cairo_curve_to (cr, 0.62, 0.26, 0.70, 0.34, 0.70, 0.45);
    cairo_curve_to (cr, 0.70, 0.59, 0.58, 0.70, 0.44, 0.70);
    cairo_curve_to (cr, 0.29, 0.70, 0.18, 0.58, 0.18, 0.40);
    cairo_close_path (cr);
    cairo_restore (cr);
    cairo_fill (cr);
}

static void
vsd_draw_time_digit (cairo_t *cr,
                     int      digit,
                     double   x,
                     double   y,
                     double   s)
{
    if (digit == 2)
        vsd_time_digit2 (cr, x + 0.02 * s, y, s);
    else if (digit == 3)
        vsd_time_digit3 (cr, x + 0.04 * s, y, s);
    else
        vsd_time_digit4 (cr, x, y, s);
}

static void
vsd_draw_accidental (cairo_t *cr,
                     int      kind,
                     double   x,
                     double   y,
                     double   s)
{
    cairo_save (cr);
    cairo_translate (cr, x, y);
    cairo_scale (cr, s, s);
    if (kind == VSD_ACC_SHARP)
    {
        cairo_rectangle (cr, -0.27, -1.30, 0.10, 2.50);
        cairo_rectangle (cr, 0.17, -1.20, 0.10, 2.50);
        for (int k = -1; k <= 1; k += 2)
        {
            double yy = k * 0.42;

            cairo_move_to (cr, -0.45, yy + 0.06);
            cairo_line_to (cr, 0.45, yy - 0.16);
            cairo_line_to (cr, 0.45, yy + 0.10);
            cairo_line_to (cr, -0.45, yy + 0.32);
            cairo_close_path (cr);
        }
    }
    else
    {
        cairo_rectangle (cr, -0.27, -1.25, 0.10, 1.80);
        cairo_rectangle (cr, 0.17, -0.55, 0.10, 1.80);
        cairo_move_to (cr, -0.27, -0.30);
        cairo_line_to (cr, 0.27, -0.46);
        cairo_line_to (cr, 0.27, -0.20);
        cairo_line_to (cr, -0.27, -0.04);
        cairo_close_path (cr);
        cairo_move_to (cr, -0.27, 0.36);
        cairo_line_to (cr, 0.27, 0.20);
        cairo_line_to (cr, 0.27, 0.46);
        cairo_line_to (cr, -0.27, 0.62);
        cairo_close_path (cr);
    }
    cairo_restore (cr);
    cairo_fill (cr);
}

#define VSD_S  VSD_COL_STACCATO
#define VSD_B  VSD_COL_BAR
#define VSD_L  VSD_COL_SYSTEM
#define VSD_T  VSD_COL_TRIPLET
#define VSD_P  VSD_COL_SPLIT

static const VsdCol vsd_cols_mp3[] = {
    { 6,  8, 1, VSD_S, 0 },
    { 5,  8, 1, VSD_S, 0 },
    { 4,  8, 1, VSD_S, 0 },
    { 3,  8, 1, VSD_S, 0 },
    { 2,  8, 2, VSD_S, 0 },
    { 4,  8, 2, VSD_S, 0 },
    { 2,  4, 0, VSD_S | VSD_L, 0 },
    { 3,  8, 3, VSD_S, VSD_ACC_SHARP },
    { 5,  8, 3, VSD_S, 0 },
    { 3,  4, 0, VSD_S, 0 },
    { 3,  8, 4, VSD_S, VSD_ACC_NATURAL },
    { 5,  8, 4, VSD_S, VSD_ACC_NATURAL },
    { 3,  4, 0, VSD_S, 0 },
};

static const VsdCol vsd_cols_wav[] = {
    { 3,  8, 1, VSD_S, 0 },
    { 3, 16, 1, VSD_S, 0 },
    { 3, 16, 1, VSD_S, 0 },
    { 3, 16, 2, VSD_S, 0 },
    { 6, 16, 2, VSD_S, 0 },
    { 7, 16, 2, VSD_S, 0 },
    { 6, 16, 2, VSD_S | VSD_B, 0 },
    { 3,  8, 3, VSD_S, 0 },
    { 3, 16, 3, VSD_S, 0 },
    { 3, 16, 3, VSD_S, 0 },
    { 3, 16, 4, VSD_S, 0 },
    { 2, 16, 4, VSD_S, 0 },
    { 1, 16, 4, VSD_S, 0 },
    { 2, 16, 4, VSD_S, 0 },
};

static const VsdCol vsd_cols_flac[] = {
    {  8, 16, 1, 0, 0 }, {  4, 16, 1, 0, 0 }, { -1, 16, 1, 0, 0 }, {  0, 16, 1, 0, 0 },
    { -1, 16, 2, 0, 0 }, {  4, 16, 2, 0, 0 }, { -1, 16, 2, 0, 0 }, {  4, 16, 2, 0, 0 },
    {  8, 16, 3, 0, 0 }, {  4, 16, 3, 0, 0 }, { -1, 16, 3, 0, 0 }, {  0, 16, 3, 0, 0 },
    { -1, 16, 4, 0, 0 }, {  4, 16, 4, 0, 0 }, { -1, 16, 4, 0, 0 }, {  4, 16, 4, 0, 0 },
};

static const VsdCol vsd_cols_ogg[] = {
    { -6, 8, 1, 0, 0 },
    { -5, 8, 1, 0, 0 },
    {  0, 4, 0, 0, 0 },
    { -1, 4, 0, VSD_B, 0 },
    { -4, 8, 2, 0, 0 },
    { -3, 8, 2, 0, 0 },
    {  2, 4, 0, 0, 0 },
    {  1, 4, 0, VSD_L, 0 },
    { -3, 8, 3, 0, 0 },
    { -2, 8, 3, 0, 0 },
    {  3, 4, 0, 0, 0 },
    {  1, 4, 0, 0, 0 },
};

static const VsdCol vsd_cols_aac[] = {
    { 4,  8, 1, 0, 0 }, { 4, 16, 1, 0, 0 }, { 4, 16, 1, VSD_T, 0 }, { 4, 16, 1, 0, 0 },
    { 4,  8, 2, 0, 0 }, { 4, 16, 2, 0, 0 }, { 4, 16, 2, VSD_T, 0 }, { 4, 16, 2, 0, 0 },
    { 4,  8, 3, 0, 0 }, { 4,  8, 3, VSD_L, 0 },
    { 4,  8, 4, 0, 0 }, { 4, 16, 4, 0, 0 }, { 4, 16, 4, VSD_T, 0 }, { 4, 16, 4, 0, 0 },
    { 4,  8, 5, 0, 0 }, { 4, 16, 5, 0, 0 }, { 4, 16, 5, VSD_T, 0 }, { 4, 16, 5, 0, 0 },
    { 4, 16, 6, 0, 0 }, { 4, 16, 6, VSD_T, 0 }, { 4, 16, 6, 0, 0 },
    { 4, 16, 6, VSD_P, 0 }, { 4, 16, 6, VSD_T, 0 }, { 4, 16, 6, 0, 0 },
};

#undef VSD_S
#undef VSD_B
#undef VSD_L
#undef VSD_T
#undef VSD_P

static const VsdScore vsd_scores[] = {
    [VSD_CARD_MP3]  = { { 1.000, 0.972, 0.968 }, { 0.958, 0.905, 0.898 }, { 0.46, 0.20, 0.18 },
                        VSD_CLEF_BASS, 5, 2, 4, vsd_cols_mp3, G_N_ELEMENTS (vsd_cols_mp3) },
    [VSD_CARD_WAV]  = { { 1.000, 0.988, 0.950 }, { 0.955, 0.930, 0.855 }, { 0.42, 0.34, 0.14 },
                        VSD_CLEF_TREBLE, 5, 0, 2, vsd_cols_wav, G_N_ELEMENTS (vsd_cols_wav) },
    [VSD_CARD_FLAC] = { { 0.976, 0.976, 0.976 }, { 0.905, 0.905, 0.905 }, { 0.30, 0.30, 0.30 },
                        VSD_CLEF_BASS, 5, 1, 4, vsd_cols_flac, G_N_ELEMENTS (vsd_cols_flac) },
    [VSD_CARD_OGG]  = { { 0.972, 0.992, 0.966 }, { 0.900, 0.940, 0.890 }, { 0.20, 0.36, 0.20 },
                        VSD_CLEF_TREBLE, 5, 3, 3, vsd_cols_ogg, G_N_ELEMENTS (vsd_cols_ogg) },
    [VSD_CARD_AAC]  = { { 0.984, 0.972, 1.000 }, { 0.925, 0.905, 0.958 }, { 0.33, 0.24, 0.45 },
                        VSD_CLEF_DRUMS, 1, 0, 3, vsd_cols_aac, G_N_ELEMENTS (vsd_cols_aac) },
};

static const gint8 vsd_sharp_pos[2][5] = {
    { 0, 3, -1, 2, 5 },
    { 2, 5,  1, 4, 7 },
};

static double
vsd_col_space (guint8 dur)
{
    return dur >= 16 ? 1.4 : dur == 8 ? 1.8 : dur == 4 ? 2.5 : 3.8;
}

static gboolean
vsd_stems_up (const VsdScore *score,
              guint           from,
              guint           to)
{
    int far = 0;

    if (score->clef == VSD_CLEF_DRUMS)
        return TRUE;
    for (guint i = from; i < to; i++)
    {
        int p = score->cols[i].head;

        if (ABS (p - 4) > ABS (far))
            far = p - 4;
    }
    return far > 0;
}

static void
vsd_draw_ledgers (cairo_t *cr,
                  double   x,
                  int      pos,
                  double   top,
                  double   sp)
{
    for (int p = 10; p <= pos; p += 2)
    {
        cairo_move_to (cr, x - 0.95 * sp, top + p * sp / 2);
        cairo_line_to (cr, x + 0.95 * sp, top + p * sp / 2);
    }
    for (int p = -2; p >= pos; p -= 2)
    {
        cairo_move_to (cr, x - 0.95 * sp, top + p * sp / 2);
        cairo_line_to (cr, x + 0.95 * sp, top + p * sp / 2);
    }
    cairo_stroke (cr);
}

static void
vsd_draw_score_card (cairo_t        *cr,
                     int             size,
                     const VsdScore *score)
{
    const double clef_w = score->clef == VSD_CLEF_TREBLE ? 2.7 : score->clef == VSD_CLEF_BASS ? 3.1 : 1.6;
    const double key_w = score->sharps > 0 ? score->sharps * 0.95 + 0.4 : 0.0;
    double left = size * 0.10, right = size * 0.90, width_units, units_max = 0.0, sp, line, dist, first;
    double header[VSD_MAX_SYSTEMS], natural[VSD_MAX_SYSTEMS], fixed[VSD_MAX_SYSTEMS];
    guint from[VSD_MAX_SYSTEMS], to[VSD_MAX_SYSTEMS], systems = 0, n = score->n_cols;
    double *x, *top, *stem_end;
    gboolean *up;

    for (guint i = 0, start = 0; i < n && systems < VSD_MAX_SYSTEMS; i++)
    {
        if ((score->cols[i].bits & VSD_COL_SYSTEM) || i + 1 == n)
        {
            from[systems] = start;
            to[systems] = i + 1;
            systems++;
            start = i + 1;
        }
    }
    n = to[systems - 1];

    for (guint k = 0; k < systems; k++)
    {
        header[k] = clef_w + 0.5 + key_w + (k == 0 ? 2.6 : 0.3);
        natural[k] = 0.0;
        fixed[k] = 0.3;
        for (guint i = from[k]; i < to[k]; i++)
        {
            natural[k] += vsd_col_space (score->cols[i].dur);
            if (score->cols[i].acc != 0)
                fixed[k] += 1.0;
            if ((score->cols[i].bits & VSD_COL_BAR) && i + 1 < to[k])
                fixed[k] += 0.9;
        }
        units_max = MAX (units_max, header[k] + natural[k] + fixed[k]);
    }
    sp = (right - left) / units_max;
    width_units = units_max;
    line = MAX (0.8, sp * 0.09);
    dist = (score->lines == 1 ? 7.0 : 9.0) * sp;
    first = size * (systems > 1 ? 0.555 : 0.58) - (systems - 1) * dist / 2 + (score->lines == 1 ? 1.2 * sp : 0.0);
    x = g_newa (double, n);
    top = g_newa (double, n);
    stem_end = g_newa (double, n);
    up = g_newa (gboolean, n);

    vsd_draw_paper (cr, size, score->center, score->edge, score->frame);

    for (guint k = 0; k < systems; k++)
    {
        double t = first + k * dist - 2 * sp;
        double stretch = natural[k] > 0 ? (width_units - header[k] - fixed[k]) / natural[k] : 1.0;
        double sys_right = right, cursor, bar_top, bar_bottom;

        if (k > 0 && k + 1 == systems && stretch > 1.35)
        {
            stretch = 1.1;
            sys_right = left + (header[k] + natural[k] * stretch + fixed[k]) * sp;
        }
        bar_top = score->lines == 1 ? t + sp : t;
        bar_bottom = score->lines == 1 ? t + 3 * sp : t + 4 * sp;

        vsd_draw_staff (cr, left, sys_right, t, sp, score->lines);
        vsd_draw_clef (cr, score->clef, left + 0.15 * sp, t, sp);
        for (int s = 0; s < score->sharps && s < 5; s++)
            vsd_draw_accidental (cr, VSD_ACC_SHARP, left + (clef_w + 0.5 + 0.45 + s * 0.95) * sp,
                                 t + vsd_sharp_pos[score->clef == VSD_CLEF_BASS][s] * sp / 2, sp);
        cursor = left + (clef_w + 0.5 + key_w) * sp;
        if (k == 0)
        {
            vsd_draw_time_digit (cr, score->beats, cursor, t, sp);
            vsd_draw_time_digit (cr, 4, cursor, t + 2 * sp, sp);
            cursor += 2.6 * sp;
        }
        else
        {
            cursor += 0.3 * sp;
        }

        cairo_set_line_cap (cr, CAIRO_LINE_CAP_BUTT);
        cairo_set_line_width (cr, line);
        for (guint i = from[k]; i < to[k]; i++)
        {
            if (score->cols[i].acc != 0)
                cursor += 1.0 * sp;
            x[i] = cursor + 0.6 * sp;
            top[i] = t;
            cursor += vsd_col_space (score->cols[i].dur) * stretch * sp;
            if ((score->cols[i].bits & VSD_COL_BAR) && i + 1 < to[k])
            {
                cairo_move_to (cr, cursor + 0.2 * sp, bar_top);
                cairo_line_to (cr, cursor + 0.2 * sp, bar_bottom);
                cursor += 0.9 * sp;
            }
        }
        cairo_move_to (cr, sys_right - line / 2, bar_top);
        cairo_line_to (cr, sys_right - line / 2, bar_bottom);
        cairo_stroke (cr);
    }

    for (guint i = 0; i < n; )
    {
        const VsdCol *c = &score->cols[i];
        guint j = i + 1;

        while (c->beam != 0 && j < n && score->cols[j].beam == c->beam && top[j] == top[i])
            j++;
        for (guint k = i; k < j; k++)
            up[k] = vsd_stems_up (score, i, j);
        if (j - i > 1)
        {
            gboolean u = up[i];
            int beams = 1;
            double t = top[i], len, min_len, y0, y1, dy, shift = 0.0, sx0, sx1, h = u ? 0.48 * sp : -0.48 * sp;

            for (guint k = i; k < j; k++)
                if (score->cols[k].dur >= 16)
                    beams = 2;
            len = (3.3 + 0.5 * (beams - 1)) * sp;
            min_len = (2.9 + 0.6 * (beams - 1)) * sp;
            sx0 = x[i] + (u ? 0.51 : -0.51) * sp;
            sx1 = x[j - 1] + (u ? 0.51 : -0.51) * sp;
            y0 = t + c->head * sp / 2 + (u ? -len : len);
            y1 = t + score->cols[j - 1].head * sp / 2 + (u ? -len : len);
            dy = CLAMP (y1 - y0, -0.9 * sp, 0.9 * sp);
            for (guint k = i; k < j; k++)
            {
                double sx = x[k] + (u ? 0.51 : -0.51) * sp;
                double b = y0 + dy * (sx - sx0) / (sx1 - sx0);
                double head = t + score->cols[k].head * sp / 2;

                shift = MAX (shift, u ? b - (head - min_len) : (head + min_len) - b);
            }
            y0 += u ? -shift : shift;
            for (guint k = i; k < j; k++)
            {
                double sx = x[k] + (u ? 0.51 : -0.51) * sp;

                stem_end[k] = y0 + dy * (sx - sx0) / (sx1 - sx0);
            }
            sx0 -= line / 2;
            sx1 += line / 2;
            cairo_move_to (cr, sx0, y0);
            cairo_line_to (cr, sx1, y0 + dy);
            cairo_line_to (cr, sx1, y0 + dy + h);
            cairo_line_to (cr, sx0, y0 + h);
            cairo_close_path (cr);
            for (guint k = i; k + 1 < j; k++)
            {
                double ax, bx, off = u ? 0.75 * sp : -0.75 * sp;

                if (score->cols[k].dur < 16 || score->cols[k + 1].dur < 16 ||
                    (score->cols[k + 1].bits & VSD_COL_SPLIT))
                    continue;
                ax = x[k] + (u ? 0.51 : -0.51) * sp - line / 2;
                bx = x[k + 1] + (u ? 0.51 : -0.51) * sp + line / 2;
                cairo_move_to (cr, ax, y0 + off + dy * (ax - sx0) / (sx1 - sx0));
                cairo_line_to (cr, bx, y0 + off + dy * (bx - sx0) / (sx1 - sx0));
                cairo_line_to (cr, bx, y0 + off + h + dy * (bx - sx0) / (sx1 - sx0));
                cairo_line_to (cr, ax, y0 + off + h + dy * (ax - sx0) / (sx1 - sx0));
                cairo_close_path (cr);
            }
            cairo_fill (cr);
        }
        else
        {
            stem_end[i] = top[i] + c->head * sp / 2 + (up[i] ? -3.3 * sp : 3.3 * sp);
        }
        i = j;
    }

    for (guint i = 0; i < n; i++)
    {
        const VsdCol *c = &score->cols[i];
        double y = top[i] + c->head * sp / 2;
        double sx = x[i] + (up[i] ? 0.51 : -0.51) * sp;

        if (score->lines == 5)
        {
            cairo_set_line_width (cr, line);
            vsd_draw_ledgers (cr, x[i], c->head, top[i], sp);
        }
        cairo_set_line_width (cr, line);
        cairo_move_to (cr, sx, y + (up[i] ? -0.1 : 0.1) * sp);
        cairo_line_to (cr, sx, stem_end[i]);
        cairo_stroke (cr);
        vsd_notehead (cr, x[i], y, sp);
        if (c->acc != 0)
            vsd_draw_accidental (cr, c->acc, x[i] - (c->acc == VSD_ACC_SHARP ? 1.25 : 1.05) * sp, y, sp);

        if (c->bits & VSD_COL_STACCATO)
        {
            int dot = up[i] ? c->head + 2 : c->head - 2;

            if (dot >= 0 && dot <= 8 && dot % 2 == 0)
                dot += up[i] ? 1 : -1;
            cairo_new_sub_path (cr);
            cairo_arc (cr, x[i], top[i] + dot * sp / 2, 0.17 * sp, 0, 2 * G_PI);
            cairo_fill (cr);
        }
        if (c->bits & VSD_COL_TRIPLET)
        {
            double ty = up[i] ? stem_end[i] - 1.35 * sp : stem_end[i] + 0.35 * sp;

            vsd_time_digit3 (cr, sx - 0.38 * sp, ty, 0.5 * sp);
        }
    }
}

static void
vsd_draw_video_card (cairo_t *cr,
                     int      size)
{
    cairo_pattern_t *g = cairo_pattern_create_linear (0, 0, 0, size);
    double k = size * 0.42 / 10.0;

    cairo_pattern_add_color_stop_rgb (g, 0, 0.37, 0.36, 0.39);
    cairo_pattern_add_color_stop_rgb (g, 1, 0.20, 0.19, 0.22);
    cairo_rectangle (cr, 0, 0, size, size);
    cairo_set_source (cr, g);
    cairo_fill (cr);
    cairo_pattern_destroy (g);

    cairo_set_source_rgba (cr, 1, 1, 1, 0.92);
    cairo_set_line_cap (cr, CAIRO_LINE_CAP_ROUND);
    cairo_set_line_join (cr, CAIRO_LINE_JOIN_ROUND);
    cairo_set_line_width (cr, VSD_GLYPH_STROKE * k);
    vsd_draw_icon (cr, TRUE, (size - 9 * k) / 2 + k, (size - 10 * k) / 2 + size * 0.06, k);
}

static VsdCard
vsd_card_for (const char *format)
{
    if (format == NULL)
        return VSD_CARD_CLASSIC;
    if (g_str_equal (format, "MPEG audio"))
        return VSD_CARD_MP3;
    if (g_str_equal (format, "WAV"))
        return VSD_CARD_WAV;
    if (g_str_equal (format, "FLAC"))
        return VSD_CARD_FLAC;
    if (g_str_equal (format, "Ogg"))
        return VSD_CARD_OGG;
    if (g_str_equal (format, "AAC ADTS"))
        return VSD_CARD_AAC;
    return VSD_CARD_CLASSIC;
}

static cairo_surface_t *
vsd_make_tile (int      size,
               gboolean video,
               VsdCard  card)
{
    cairo_surface_t *s = cairo_image_surface_create (CAIRO_FORMAT_RGB24, size, size);
    cairo_t *cr = cairo_create (s);

    if (video)
        vsd_draw_video_card (cr, size);
    else if (card == VSD_CARD_CLASSIC)
        vsd_draw_music_card (cr, size);
    else
        vsd_draw_score_card (cr, size, &vsd_scores[card]);
    cairo_destroy (cr);
    return s;
}

static gboolean
vsd_save_png (cairo_surface_t *s,
              const char      *path)
{
    g_autofree char *tmp = g_strconcat (path, ".nvsd-tmp.png", NULL);

    if (cairo_surface_write_to_png (s, tmp) != CAIRO_STATUS_SUCCESS)
    {
        g_unlink (tmp);
        return FALSE;
    }
    if (g_rename (tmp, path) != 0)
    {
        g_unlink (tmp);
        return FALSE;
    }
    return TRUE;
}

static char **
vsd_thumbnailer_dirs (void)
{
    GPtrArray *dirs = g_ptr_array_new_with_free_func (g_free);
    const char *const *sys = g_get_system_data_dirs ();
    const char *const fallback[] = { "/usr/local/share", "/usr/share", NULL };

    g_ptr_array_add (dirs, g_build_filename (g_get_user_data_dir (), "thumbnailers", NULL));
    for (int pass = 0; pass < 2; pass++)
    {
        for (const char *const *d = pass == 0 ? sys : fallback; *d != NULL; d++)
        {
            g_autofree char *path = g_build_filename (*d, "thumbnailers", NULL);
            gboolean dup = FALSE;

            for (guint i = 0; i < dirs->len; i++)
                dup |= g_str_equal (dirs->pdata[i], path);
            if (!dup)
                g_ptr_array_add (dirs, g_steal_pointer (&path));
        }
    }
    g_ptr_array_add (dirs, NULL);
    return (char **) g_ptr_array_free (dirs, FALSE);
}

static char *
vsd_find_original (const char *mime)
{
    g_auto (GStrv) dirs = vsd_thumbnailer_dirs ();

    for (int pass = 0; pass < 2; pass++)
    {
        for (char **d = dirs; *d != NULL; d++)
        {
            g_autoptr (GDir) dir = g_dir_open (*d, 0, NULL);
            const char *name;

            while (dir != NULL && (name = g_dir_read_name (dir)) != NULL)
            {
                g_autoptr (GKeyFile) kf = g_key_file_new ();
                g_autofree char *path = NULL, *exec = NULL, *try_exec = NULL;
                g_auto (GStrv) mimes = NULL, argv = NULL;
                gboolean match = FALSE;

                if (!g_str_has_suffix (name, ".thumbnailer") || g_str_has_prefix (name, VSD_THUMB_FILE_PFX))
                    continue;
                path = g_build_filename (*d, name, NULL);
                if (!g_key_file_load_from_file (kf, path, 0, NULL))
                    continue;
                exec = g_key_file_get_string (kf, "Thumbnailer Entry", "Exec", NULL);
                mimes = g_key_file_get_string_list (kf, "Thumbnailer Entry", "MimeType", NULL, NULL);
                if (exec == NULL || mimes == NULL || !g_shell_parse_argv (exec, NULL, &argv, NULL))
                    continue;
                {
                    g_autofree char *base = g_path_get_basename (argv[0]);
                    if (g_str_equal (base, VSD_THUMB_NAME))
                        continue;
                }
                try_exec = g_key_file_get_string (kf, "Thumbnailer Entry", "TryExec", NULL);
                if (try_exec != NULL)
                {
                    g_autofree char *found = g_find_program_in_path (try_exec);
                    if (found == NULL)
                        continue;
                }
                for (char **m = mimes; *m != NULL && !match; m++)
                    match = pass == 0 ? g_ascii_strcasecmp (*m, mime) == 0
                                      : g_content_type_equals (*m, mime);
                if (match)
                    return g_steal_pointer (&exec);
            }
        }
    }
    return NULL;
}

static char *
vsd_expand (const char *elem,
            int         size,
            const char *mime,
            const char *in,
            const char *out)
{
    GString *str = g_string_new (NULL);

    for (const char *p = elem; *p; p++)
    {
        if (*p != '%' || p[1] == '\0')
        {
            g_string_append_c (str, *p);
            continue;
        }
        switch (*++p)
        {
            case 'u':
            {
                g_autofree char *uri = g_filename_to_uri (in, NULL, NULL);
                g_string_append (str, uri ? uri : in);
                break;
            }
            case 'i': g_string_append (str, in); break;
            case 'o': g_string_append (str, out); break;
            case 's': g_string_append_printf (str, "%d", size); break;
            case 'm': g_string_append (str, mime); break;
            case '%': g_string_append_c (str, '%'); break;
            default:  g_string_append_c (str, '%'); g_string_append_c (str, *p); break;
        }
    }
    return g_string_free (str, FALSE);
}

static gboolean
vsd_run_original (const char *exec,
                  int         size,
                  const char *mime,
                  const char *in,
                  const char *out)
{
    g_auto (GStrv) argv = NULL;
    g_autoptr (GError) error = NULL;
    int status = 0;

    if (!g_shell_parse_argv (exec, NULL, &argv, NULL))
        return FALSE;
    for (char **a = argv; *a != NULL; a++)
    {
        char *e = vsd_expand (*a, size, mime, in, out);
        g_free (*a);
        *a = e;
    }
    g_setenv (VSD_THUMB_GUARD, "1", TRUE);
    if (!g_spawn_sync (NULL, argv, NULL, G_SPAWN_SEARCH_PATH, NULL, NULL, NULL, NULL, &status, &error))
    {
        g_printerr ("%s: %s\n", VSD_THUMB_NAME, error->message);
        return FALSE;
    }
    if (!g_spawn_check_wait_status (status, NULL))
        return FALSE;
    return g_file_test (out, G_FILE_TEST_IS_REGULAR);
}

static int
vsd_thumbnailer_main (int    argc,
                      char **argv)
{
    int size = 256;
    const char *in = NULL, *out = NULL, *mime_arg = NULL;
    g_autofree char *mime = NULL, *label = NULL, *orig = NULL, *in_path = NULL;
    g_autoptr (GFile) file = NULL;
    VsdMedia media;
    gboolean video, have_thumb = FALSE;
    guint hints = 0;
    cairo_surface_t *surface;

    for (int i = 1; i < argc; i++)
    {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;

        if (g_str_equal (a, "--version"))
        {
            g_print ("%s\n", VSD_THUMB_NAME);
            return 0;
        }
        if (v == NULL)
            break;
        if (g_str_equal (a, "-s"))      size = atoi (v);
        else if (g_str_equal (a, "-i")) in = v;
        else if (g_str_equal (a, "-u")) in_path = g_filename_from_uri (v, NULL, NULL);
        else if (g_str_equal (a, "-o")) out = v;
        else if (g_str_equal (a, "-m")) mime_arg = v;
        else continue;
        i++;
    }
    if (in == NULL)
        in = in_path;
    if (in == NULL || out == NULL)
    {
        g_printerr ("Usage: %s -s SIZE -i INPUT -o OUTPUT.png [-m MIME/TYPE]\n", VSD_THUMB_NAME);
        return 2;
    }
    if (g_getenv (VSD_THUMB_GUARD) != NULL)
        return 1;
    size = CLAMP (size, 16, 2048);

    if (mime_arg != NULL && strchr (mime_arg, '/') != NULL)
    {
        mime = g_strdup (mime_arg);
    }
    else
    {
        guint8 head[4096];
        gsize n = 0;
        FILE *f = fopen (in, "rb");
        if (f != NULL)
        {
            n = fread (head, 1, sizeof head, f);
            fclose (f);
        }
        g_autofree char *ct = g_content_type_guess (in, head, n, NULL);
        mime = g_content_type_get_mime_type (ct);
        if (mime == NULL)
            mime = g_strdup ("application/octet-stream");
    }

    {
        g_autofree char *lower = g_ascii_strdown (in, -1);
        if (g_str_has_suffix (lower, ".mp3") || g_str_has_suffix (lower, ".mp2") ||
            g_str_has_suffix (lower, ".aac") || g_str_equal (mime, "audio/mpeg") ||
            g_str_has_prefix (mime, "audio/aac") || g_str_has_prefix (mime, "audio/x-aac") ||
            g_str_has_prefix (mime, "audio/mp"))
            hints |= VSD_HINT_MPEG_AUDIO;
    }

    file = g_file_new_for_path (in);
    if (vsd_probe (file, hints, NULL, &media))
        label = vsd_format_human (media.seconds);
    else
        memset (&media, 0, sizeof media);
    video = media.width > 0 || g_str_has_prefix (mime, "video/");

    orig = vsd_find_original (mime);
    if (orig != NULL)
        have_thumb = vsd_run_original (orig, size, mime, in, out);

    if (have_thumb)
    {
        cairo_surface_t *png;
        cairo_t *cr;
        int w, h;

        if (label == NULL)
            return 0;
        png = cairo_image_surface_create_from_png (out);
        if (cairo_surface_status (png) != CAIRO_STATUS_SUCCESS)
        {
            cairo_surface_destroy (png);
            return 0;
        }
        w = cairo_image_surface_get_width (png);
        h = cairo_image_surface_get_height (png);
        cr = cairo_create (png);
        vsd_draw_badge (cr, w, h, label, video);
        cairo_destroy (cr);
        vsd_save_png (png, out);
        cairo_surface_destroy (png);
        return 0;
    }

    if (label == NULL)
        return 1;

    surface = vsd_make_tile (size, video, vsd_card_for (media.format));
    {
        cairo_t *cr = cairo_create (surface);
        vsd_draw_badge (cr, size, size, label, video);
        cairo_destroy (cr);
    }
    have_thumb = vsd_save_png (surface, out);
    cairo_surface_destroy (surface);
    return have_thumb ? 0 : 1;
}

int
main (int    argc,
      char **argv)
{
    return vsd_thumbnailer_main (argc, argv);
}
#endif
C_SOURCE
}

OS_ID="" OS_LIKE="" OS_VERSION="" OS_PRETTY="" FAMILY="unknown"
PKGS=()

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
                FAMILY=fedora; PKGS=(gcc pkgconf-pkg-config nautilus-devel cairo-devel); break ;;
            debian|ubuntu|linuxmint|pop|elementary|zorin|kali|raspbian|neon|devuan)
                FAMILY=debian; PKGS=(gcc libc6-dev pkg-config libnautilus-extension-dev libcairo2-dev); break ;;
            arch|archlinux|manjaro|endeavouros|cachyos|garuda|artix)
                FAMILY=arch; PKGS=(gcc pkgconf libnautilus-extension cairo); break ;;
            opensuse*|suse|sles)
                FAMILY=suse; PKGS=(gcc pkg-config nautilus-devel cairo-devel); break ;;
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
    flags="$(pkg-config --cflags --libs "$PC" gio-2.0 gmodule-no-export-2.0)"
    msg "$(t 'Kompilacja (libnautilus-extension %s)' 'Compiling (libnautilus-extension %s)')" "$(pkg-config --modversion "$PC" 2>/dev/null || echo '?')"
    gcc -std=gnu11 -O2 -g -Wall -Wextra -fPIC -shared \
        -Wl,--no-undefined -Wl,-z,relro,-z,now \
        -o "$out" "$BUILD_DIR/$EXT_NAME.c" $flags
}

compile_thumbnailer() {
    local out="$1" flags
    if ! pkg-config --exists cairo gio-2.0; then
        warn "$(t 'Brak nagłówków cairo; pomijam widok siatki (kolumny działają).' 'cairo headers missing; skipping the grid view (columns still work).')"
        return 1
    fi
    [[ -f "$BUILD_DIR/$EXT_NAME.c" ]] || write_source "$BUILD_DIR/$EXT_NAME.c"
    flags="$(pkg-config --cflags --libs gio-2.0 cairo)"
    msg "$(t 'Kompilacja miniaturyzera widoku siatki (cairo %s)' 'Compiling the grid-view thumbnailer (cairo %s)')" "$(pkg-config --modversion cairo 2>/dev/null || echo '?')"
    gcc -std=gnu11 -O2 -g -Wall -Wextra -DVSD_THUMBNAILER \
        -Wl,-z,relro,-z,now -fPIE -pie \
        -o "$out" "$BUILD_DIR/$EXT_NAME.c" $flags -lm
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

purge_media_thumbnails() {
    [[ -d "$THUMB_CACHE" ]] || return 0
    local d dirs=() files=()
    for d in normal large x-large xx-large fail; do
        [[ -d "$THUMB_CACHE/$d" ]] && dirs+=("$THUMB_CACHE/$d")
    done
    (( ${#dirs[@]} )) || return 0
    mapfile -d '' -t files < <(LC_ALL=C grep -ralZiE --include='*.png' \
        "Thumb::URI.file://[^[:cntrl:]]*\.(${MEDIA_EXT_RE})" -- "${dirs[@]}" 2>/dev/null || true)
    (( ${#files[@]} )) || return 0
    printf '%s\0' "${files[@]}" | xargs -0 rm -f --
    msg "$(t 'Usunięte z pamięci podręcznej miniatury audio/wideo: %s (wygenerują się ponownie).' 'Removed cached audio/video thumbnails: %s (they will be regenerated).')" "${#files[@]}"
}

write_thumbnailer_entry() {
    local mimes="$1"
    mkdir -p "$THUMB_DIR"
    cat > "$THUMB_DIR/$THUMB_FILE" <<EOF
[Thumbnailer Entry]
TryExec=$THUMB_BIN
Exec=$THUMB_BIN -s %s -m %m -i %i -o %o
MimeType=$mimes
EOF
    msg "$(t 'Zapisano %s' 'Written %s')" "$THUMB_DIR/$THUMB_FILE"
}

grid_installed() {
    [[ -e "$THUMB_BIN" || -e "$THUMB_DIR/$THUMB_FILE" ]]
}

grid_remove() {
    local removed=1
    if [[ -e "$THUMB_DIR/$THUMB_FILE" ]]; then
        msg "$(t 'Usuwanie %s' 'Removing %s')" "$THUMB_DIR/$THUMB_FILE"
        rm -f -- "$THUMB_DIR/$THUMB_FILE"
        removed=0
    fi
    if [[ -e "$THUMB_BIN" ]]; then
        msg "$(t 'Usuwanie %s' 'Removing %s')" "$THUMB_BIN"
        as_root rm -f "$THUMB_BIN"
        removed=0
    fi
    (( removed == 0 )) && purge_media_thumbnails
    return $removed
}

grid_install() {
    local mode="$1" mimes target
    case "$mode" in
        all)   mimes="$VIDEO_MIMES$AUDIO_MIMES" ;;
        video) mimes="$VIDEO_MIMES" ;;
    esac

    target="$(readlink -f "$(dirname "$THUMB_BIN")" 2>/dev/null || dirname "$THUMB_BIN")"
    if [[ "$target" != /usr/* ]]; then
        warn "$(t '%s nie leży pod /usr (piaskownica miniatur go nie zobaczy); pomijam widok siatki.' '%s is not under /usr (the thumbnail sandbox cannot see it); skipping the grid view.')" "$(dirname "$THUMB_BIN")"
        return 0
    fi

    compile_thumbnailer "$BUILD_DIR/${EXT_NAME}-thumbnailer" || {
        warn "$(t 'Widok siatki pominięty.' 'Grid view skipped.')"
        return 0
    }
    msg "$(t 'Instalacja do %s' 'Installing to %s')" "$THUMB_BIN"
    as_root install -Dm755 "$BUILD_DIR/${EXT_NAME}-thumbnailer" "$THUMB_BIN"
    if command -v restorecon >/dev/null; then
        as_root restorecon "$THUMB_BIN" || true
    fi
    write_thumbnailer_entry "$mimes"
    purge_media_thumbnails
}

cmd_install() {
    local show_by_default=0 grid=all arg dir
    for arg in "$@"; do
        case "$arg" in
            --show-by-default) show_by_default=1 ;;
            --grid=all|--grid=video|--grid=none) grid="${arg#--grid=}" ;;
            --no-grid) grid=none ;;
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
        as_root restorecon "$dir/$SO" || true
    fi

    (( show_by_default )) && columns_default_add

    if [[ "$grid" == none ]]; then
        grid_installed && grid_remove || true
    else
        grid_install "$grid"
    fi
    restart_nautilus

    if [[ "$UI_LANG" == pl ]]; then
        cat <<EOF

Gotowe. Aby zobaczyć kolumny:
  1. Przełącz widok na listę (Ctrl+1).
  2. Strzałka przy przycisku widoku → „Widoczne kolumny…” →
     zaznacz „Czas trwania”, „Szerokość (px)”, „Wysokość (px)”.
  3. Kliknij nagłówek kolumny, żeby sortować (ponownie: odwrotna kolejność).

Widok siatki (Ctrl+2): miniatury filmów i plików audio dostają w lewym
górnym rogu ramkę z czasem, np. „▶ 2m 4s”. Miniatury generują się od nowa,
więc w dużych folderach pojawią się stopniowo.

Porządkowanie: menu widoku (strzałka przy przycisku widoku) → sekcja
„Audio i wideo” pod „Porządkowanie”: czas trwania, szerokość albo wysokość.
To samo jest pod prawym klikiem na pustym miejscu folderu.

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

Grid view (Ctrl+2): video and audio thumbnails get a duration badge in the
top-left corner, e.g. "▶ 2m 4s". Thumbnails are regenerated, so in large
folders they appear gradually.

Sorting: view menu (arrow next to the view button) → "Audio and Video"
section below "Sort": duration, width or height. The same options are in the
right-click menu of an empty folder area.

Column labels follow the session language (Polish or English).
Uninstall:  $0 uninstall
EOF
    fi
}

cmd_uninstall() {
    [[ $EUID -ne 0 ]] || die "$(t 'Uruchom jako zwykły użytkownik.' 'Run as a regular user.')"
    detect_distro
    columns_default_remove
    local grid_removed=1
    grid_remove && grid_removed=0
    if remove_files "$SO" "$OLD_SO" || (( grid_removed == 0 )); then
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
    if compile_thumbnailer "$PWD/${EXT_NAME}-thumbnailer"; then
        msg "$(t 'Zbudowano: %s' 'Built: %s')" "$PWD/${EXT_NAME}-thumbnailer"
    fi
}

cmd_source() {
    write_source "$PWD/$EXT_NAME.c"
    msg "$(t 'Zapisano: %s' 'Written: %s')" "$PWD/$EXT_NAME.c"
}

cmd_help() {
    if [[ "$UI_LANG" == pl ]]; then
        cat <<EOF
Nautilus Video Size and Duration $NVSD_VERSION — czas trwania i rozmiar obrazu w Nautilusie (lista i siatka)

Użycie: $0 [polecenie] [opcje]

Polecenia:
  install       kompiluje i instaluje (domyślne)
  uninstall     usuwa rozszerzenie i miniaturyzer (także wersję 1)
  build         tylko kompiluje $SO i miniaturyzer do bieżącego katalogu
  source        zapisuje kod C do bieżącego katalogu
  help          ta pomoc

Opcje:
  --show-by-default   (install) kolumny widoczne domyślnie we wszystkich folderach
  --grid=all          (install, domyślne) czas na miniaturach wideo i audio w widoku siatki
  --grid=video        (install) czas tylko na miniaturach wideo
  --grid=none         (install) bez widoku siatki, tylko kolumny (także --no-grid)
  --lang pl|en        język komunikatów (domyślnie z LANG/LANGUAGE)

Obsługiwane: MP4 M4V M4A M4B MOV 3GP · MKV MKA WEBM · AVI · WMV WMA ASF
             OGG OGA OGV OPUS SPX · FLAC · WAV · MP3 MP2 · AAC
Licencja: EUPL-1.2
EOF
    else
        cat <<EOF
Nautilus Video Size and Duration $NVSD_VERSION — duration and frame size in Nautilus (list and grid)

Usage: $0 [command] [options]

Commands:
  install       compile and install (default)
  uninstall     remove the extension and thumbnailer (including version 1)
  build         only compile $SO and the thumbnailer into the current directory
  source        write the C source into the current directory
  help          this help

Options:
  --show-by-default   (install) show the columns by default in every folder
  --grid=all          (install, default) duration on video and audio thumbnails in grid view
  --grid=video        (install) duration on video thumbnails only
  --grid=none         (install) no grid view, columns only (also --no-grid)
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
