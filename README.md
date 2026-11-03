# Nautilus Video Size and Duration

Rozszerzenie menedżera plików **Nautilus (Pliki)** dla GNOME, które dodaje w widoku listy trzy sortowalne kolumny:

| Kolumna (PL) | Column (EN) | Zawartość |
|---|---|---|
| Czas trwania | Duration | czas odtwarzania plików audio i wideo, np. `3:25`, `1:02:05` |
| Szerokość (px) | Width (px) | szerokość klatki wideo w pikselach |
| Wysokość (px) | Height (px) | wysokość klatki wideo w pikselach |

Pliki audio mają wypełniony tylko czas trwania. Nazwy kolumn są po polsku albo po angielsku, zależnie od języka sesji.

Całość to jeden plik `nautilus-video-size-duration.sh`. Zawiera kod rozszerzenia w C, sam instaluje potrzebne pakiety, kompiluje i instaluje wtyczkę.

Licencja: [EUPL-1.2](LICENSE) · Autor: M.T. Jaroszek · Wersja 2.0.0

---

## Obsługiwane formaty

Format jest rozpoznawany po zawartości pliku, nie po rozszerzeniu. Plik `.mp4`, który w środku jest Matroską, zostanie więc odczytany poprawnie.

| Kontener | Rozszerzenia | Skąd czas trwania | Skąd wymiary obrazu |
|---|---|---|---|
| ISO BMFF / QuickTime | `mp4 m4v m4a m4b mov 3gp 3g2` | `moov/mvhd`; w plikach fragmentowanych (np. OBS) suma fragmentów `moof/trun` | `stsd` ścieżki wideo, z uwzględnieniem obrotu z macierzy `tkhd` |
| Matroska / WebM | `mkv mka webm` | `Info/Duration`; gdy go brak: koniec ostatniego klastra | `Tracks/Video/PixelWidth × PixelHeight` |
| AVI (RIFF) | `avi` | `strh` ścieżki wideo (klatki × skala ÷ tempo), OpenDML `dmlh` dla plików > 1 GiB | `strf` (BITMAPINFOHEADER) |
| ASF | `wmv wma asf` | File Properties: czas odtwarzania − preroll | Stream Properties (Encoded Image Width/Height) |
| Ogg | `ogg oga ogv opus spx` | granule ostatniej strony: Vorbis, Opus, FLAC, Speex, Theora | Theora: `PICW × PICH` |
| FLAC | `flac` | `STREAMINFO`: liczba próbek ÷ częstotliwość | — |
| WAV | `wav` (RIFF, RF64, BW64) | rozmiar danych ÷ blok ÷ częstotliwość; dla kompresji (ADPCM, MP3 w WAV) chunk `fact` | — |
| MPEG audio | `mp3 mp2` | nagłówek Xing/Info (LAME) lub VBRI; bez nich wyliczenie z bitrate (CBR) | — |
| AAC ADTS | `aac` | zliczenie ramek (pliki do 1 MiB dokładnie, większe szacowane ze średniej ramki) | — |

Pozostałe pliki z typem MIME `audio/…` lub `video/…` też są sprawdzane. Jeśli format nie jest obsługiwany, komórki zostają puste.

---

## Wymagania i dystrybucje

Wymagany jest Nautilus 43 lub nowszy, czyli API rozszerzeń w wersji 4. Instalator sam wykrywa dystrybucję z `/etc/os-release` (pola `ID` i `ID_LIKE`) i dobiera menedżer pakietów.

| Rodzina | Przykłady | Instalowane pakiety | Przykładowy Nautilus |
|---|---|---|---|
| Fedora (`dnf`) | Fedora 44 z GNOME 50, Nobara, RHEL/Alma/Rocky 10 | `gcc pkgconf-pkg-config nautilus-devel` | 50 (Fedora 44) |
| Debian (`apt`) | Debian 12+, Ubuntu 22.10+ (w tym 24.04 LTS) | `gcc libc6-dev pkg-config libnautilus-extension-dev` | 43 (Debian 12), 46 (Ubuntu 24.04) |
| Arch (`pacman`) | Arch, Manjaro GNOME, EndeavourOS, CachyOS | `gcc pkgconf libnautilus-extension` (nagłówki są w tym pakiecie) | 50 |
| openSUSE (`zypper`) | Tumbleweed | `gcc pkg-config nautilus-devel` | bez testów |

Rozszerzenie działa tylko z Nautilusem. Linux Mint (Nemo) i Pop!_OS (COSMIC Files) mają domyślnie inne menedżery plików. Instalator rozpozna je jako dystrybucje debianowe, ale kolumny pojawią się dopiero w doinstalowanym Nautilusie.

**Nieobsługiwane:** Ubuntu 22.04 i Debian 11 (Nautilus 42 i 3.38 mają starsze API 3) oraz systemy atomowe, takie jak Fedora Silverblue (patrz „Ograniczenia”).

Przy nierozpoznanej dystrybucji instalator nie instaluje pakietów. Spróbuje jednak skompilować wtyczkę, jeśli `gcc`, `pkg-config` i `libnautilus-extension-4.pc` są już w systemie.

---

## Instalacja

```bash
chmod +x nautilus-video-size-duration.sh
./nautilus-video-size-duration.sh                      # instalacja
./nautilus-video-size-duration.sh install --show-by-default   # + kolumny widoczne we wszystkich folderach
```

Uruchom skrypt jako zwykły użytkownik. Uprawnienia roota (przez `sudo`, `doas` lub `pkexec`) są potrzebne tylko do instalacji pakietów i skopiowania pliku `.so` do katalogu rozszerzeń. Katalog ten jest odczytywany z `pkg-config`, np. `/usr/lib64/nautilus/extensions-4` na Fedorze, `/usr/lib/x86_64-linux-gnu/nautilus/extensions-4` na Debianie i `/usr/lib/nautilus/extensions-4` na Archu.

Na koniec skrypt pyta o restart Nautilusa. Restart przerywa trwające kopiowanie plików, dlatego jest pytanie.

### Pozostałe polecenia

| Polecenie | Działanie |
|---|---|
| `uninstall` | usuwa rozszerzenie (także wersję 1) i wpisy dodane przez `--show-by-default` |
| `build` | tylko kompiluje `libnautilus-video-size-duration.so` do bieżącego katalogu, bez sudo |
| `source` | zapisuje kod C (`nautilus-video-size-duration.c`) do bieżącego katalogu |
| `help` | pomoc |
| `--lang pl\|en` | język komunikatów instalatora; domyślnie z `LANG`/`LANGUAGE` |

---

## Użycie

1. Przełącz widok na listę (**Ctrl+1**).
2. Kliknij strzałkę przy przycisku widoku, wybierz **„Widoczne kolumny…”** i zaznacz **Czas trwania**, **Szerokość (px)** i **Wysokość (px)**.
3. Kliknij nagłówek kolumny, żeby sortować. Za pierwszym razem największe wartości są na górze; kolejne kliknięcie odwraca kolejność.

Nautilus zapamiętuje widoczne kolumny osobno dla folderów, w których zmieniono ich układ. Opcja `--show-by-default` dopisuje trzy kolumny do ustawienia `org.gnome.nautilus.list-view default-visible-columns`, które obowiązuje w pozostałych folderach.

---

## Jak to działa

```
Nautilus ──update_file_info()──▶ InfoProvider
                                   │ czy to plik audio/wideo? (MIME audio/*, video/* lub rozszerzenie)
                                   │   nie → 3 puste atrybuty, koniec
                                   ▼   tak
                                 GTask w wątku roboczym
                                   │ rozpoznanie formatu po pierwszych bajtach
                                   │ parser kontenera: kilka odczytów nagłówków
                                   ▼
                                 wątek główny: add_string_attribute() ×3
                                   └─▶ update_complete → Nautilus odświeża wiersz
Nautilus ──get_columns()──▶ ColumnProvider: 3 kolumny, etykiety PL/EN
```

- **Bez zewnętrznych bibliotek.** Wszystkie parsery są napisane w C na GLib/GIO, bez GStreamera i ffmpeg. Zwykle wystarcza kilka odczytów po kilkadziesiąt bajtów na plik. Wyjątki: AAC ADTS czyta do 1 MiB, Ogg sprawdza ostatnie 128 KiB, a MKV bez pola Duration przegląda nagłówki klastrów.
- **Bez blokowania okna.** Odczyt odbywa się w wątku roboczym. Gdy Nautilus anuluje zapytanie (np. po zmianie folderu), wynik jest odrzucany zgodnie z kontraktem API.
- **Sortowanie.** Nautilus sortuje kolumny rozszerzeń funkcją `strcmp()` na wyświetlanym tekście. Dlatego wartości mają stałą szerokość i są dopełniane spacjami z lewej: `"    3:25"`, `" 1:02:05"`, `" 1920"`, `"  720"`. Kolumny są wyrównane do prawej, więc spacji nie widać, a kolejność alfabetyczna pokrywa się z liczbową. Każdy plik dostaje atrybuty, także pusty tekst, żeby porównanie było spójne w całej liście.
- **Wymiary.** Pokazywana jest liczba pikseli zapisana w pliku. Przy nagraniach pionowych z telefonu (obrót 90°/270° w MP4/MOV) szerokość i wysokość są zamienione, tak jak widzi je odtwarzacz. Przy kilku ścieżkach wideo pokazywana jest największa.
- **Bezpieczeństwo odczytu.** Wszystkie rozmiary pól są sprawdzane względem granic pliku i bufora. Parsery przeszły test na 3240 losowo uszkodzonych plikach pod AddressSanitizerem i UBSanem bez żadnego błędu.

### Języki

Etykiety kolumn wybiera funkcja `vsd_pick_strings()` na podstawie `g_get_language_names()`, czyli zmiennych `LANGUAGE`, `LC_ALL`, `LC_MESSAGES` i `LANG` sesji. Dla `pl*` są polskie, dla każdego innego języka angielskie.

Nowy język to jeden wiersz w tablicy `vsd_strings[]` w kodzie C (polecenie `source` zapisuje kod do edycji) i para tekstów w funkcji `t()` instalatora.

---

## Diagnostyka

```bash
nautilus -q
G_MESSAGES_DEBUG=VideoSizeDuration nautilus
```

W terminalu pojawi się komunikat o załadowaniu rozszerzenia oraz, dla każdego pliku, rozpoznany format, czas w sekundach i wymiary. Rozszerzenia można też chwilowo wyłączyć: `NAUTILUS_DISABLE_PLUGINS=TRUE nautilus`.

---

## Ograniczenia

- **API Nautilusa:** kolumny rozszerzeń mogą zawierać tylko tekst i są sortowane jako tekst. Nautilus pyta o pliki jednego folderu po kolei, więc w bardzo dużych folderach komórki wypełniają się stopniowo.
- **Formaty nieobsługiwane:** MPEG-TS/PS (`ts mts m2ts mpg vob`), AIFF, WavPack, Monkey's Audio, DSD. Mają puste komórki.
- **Wartości szacowane:** MP3 bez nagłówka Xing/VBRI (dokładne dla CBR, przybliżone dla VBR), AAC ADTS powyżej 1 MiB, MKV bez pola Duration (bez czasu ostatniej klatki). Ucięty plik MP3 z nagłówkiem Xing pokazuje pełną długość z nagłówka, tak samo jak ffprobe.
- **Proporcje pikseli:** pokazywane są piksele zapisane w pliku, bez przeliczania anamorficznych proporcji (PAR).
- **Pliki zdalne:** urządzenia bez przewijania strumienia (np. część telefonów przez MTP) dostaną puste komórki.
- **Czas ≥ 100 godzin** przekracza stałą szerokość pola i sortuje się wtedy niepoprawnie.
- **Fedora Silverblue / Kinoite i inne systemy rpm-ostree:** `/usr` jest tylko do odczytu, a Nautilus ładuje rozszerzenia wyłącznie z katalogu systemowego. Instalator przerywa pracę z komunikatem. Instalacja wymagałaby zbudowania pakietu RPM i dołożenia go przez `rpm-ostree install`.

---

## Co zostało sprawdzone (Claude Code)

- Kompilacja bez ostrzeżeń (`-Wall -Wextra -Wshadow -Wconversion`) z nagłówkami Nautilusa **43.0** (Debian 12), **46.4** (Ubuntu 24.04) i **50.1** (Fedora 44, Arch).
- 35 plików testowych wygenerowanych przez ffmpeg 6.1 we wszystkich formatach z tabeli. Czas zgadza się z ffprobe do 0,05 s, a wymiary dokładnie, z obrotem 90°/180°/270°. Wyjątek to AAC ADTS: ffprobe szacuje tam z bitrate (30,25 s), a rozszerzenie liczy ramki (30,53 s przy nagraniu 30,5 s).
- Testowy host, który ładuje `.so` tak jak `nautilus-module.c` i wywołuje providery tak jak `nautilus-directory-async.c`: kolumny w PL/EN, anulowanie bez odpowiedzi po `cancel_update`, sortowanie `strcmp`, pomijanie folderów, kolejek FIFO i plików pustych.
- 3240 uszkodzonych plików pod ASan/UBSan: zero błędów pamięci i wycieków w kodzie rozszerzenia.
- Instalator na atrapach menedżerów pakietów: Fedora, Ubuntu, Debian, Mint, Arch, Manjaro, openSUSE, nieznana dystrybucja, Silverblue, Nautilus 42, brak nagłówków, samo API 3, ponowienie `apt` po `apt-get update`, `--show-by-default`, odinstalowanie, usunięcie wersji 1.

Test w działającej sesji GNOME. Wersja 1, oparta na tym samym mechanizmie rozszerzenia, działa w Nautilusie Gnome 50 na Fedorze 44.

---

## Licencja

Copyright © 2026 M.T. Jaroszek. Udostępnione na licencji **Europejskiej Licencji Publicznej Unii Europejskiej (EUPL) w wersji 1.2** (`SPDX-License-Identifier: EUPL-1.2`). Pełny tekst angielski jest w pliku [LICENSE](LICENSE). Wersja polska ma równą moc prawną i jest dostępna na stronie [Interoperable Europe](https://interoperable-europe.ec.europa.eu/collection/eupl/eupl-text-eupl-12).

Rozszerzenie jest ładowane do procesu Nautilusa i linkowane z `libnautilus-extension` (GPL-3.0-or-later). Załącznik EUPL-1.2 wymienia GPL v2 i v3 jako licencje zgodne. Kod EUPL może więc wejść w skład większego dzieła rozpowszechnianego na GPL ([lista zgodnych licencji EUPL](https://interoperable-europe.ec.europa.eu/page/eupl-compatible-open-source-licences)). To opis, nie porada prawna.

---

## English

**Nautilus Video Size and Duration** adds three sortable list-view columns to GNOME Files (Nautilus 43+): **Duration**, **Width (px)** and **Height (px)**. Audio files only get a duration. Column labels follow the session language (Polish or English; any other language falls back to English).

**Formats** (detected by content, not by extension): MP4/M4V/M4A/M4B/MOV/3GP (including fragmented MP4 and rotation), MKV/MKA/WebM, AVI (including OpenDML), WMV/WMA/ASF, Ogg (Vorbis, Opus, FLAC, Speex, Theora), FLAC, WAV/RF64/BW64, MP3/MP2 (Xing, VBRI, CBR) and AAC ADTS. No GStreamer or ffmpeg is needed. Metadata is read from container headers in a worker thread.

**Install**: run `./nautilus-video-size-duration.sh` as a regular user. It detects Fedora/RHEL (dnf), Debian/Ubuntu/Mint (apt), Arch/Manjaro (pacman) or openSUSE (zypper, untested), installs `gcc`, `pkg-config` and the Nautilus extension headers, compiles the extension and copies it to the extension directory. Add `install --show-by-default` to show the columns in every folder, `uninstall` to remove it, `build` to compile only, `source` to write out the C code, and `--lang pl|en` to choose the installer language. Version 1 (`libnautilus-video-duration.so`) is removed automatically.

**Use**: list view (Ctrl+1), then the arrow next to the view button, then "Visible Columns…", and tick the three columns. Click a header to sort.

**Why the values are space-padded**: Nautilus sorts extension columns with `strcmp()` on the displayed text. Right-aligned, fixed-width values such as `"    3:25"` and `" 1920"` make text order equal numeric order.

**Not supported**: Nautilus ≤ 42 (API 3), MPEG-TS/PS, AIFF, WavPack, and rpm-ostree systems such as Silverblue (read-only `/usr`).

**Licence**: EUPL-1.2. See [LICENSE](LICENSE).
