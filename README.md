# Nautilus Video Size and Duration

Rozszerzenie Nautilusa (Pliki, GNOME) · wersja 2.6.0 · M.T. Jaroszek · [EUPL-1.2](LICENSE)

- **Widok listy:** sortowalne kolumny **Czas trwania**, **Szerokość (px)** i **Wysokość (px)** (PL/EN).
- **Widok siatki:** czas w lewym górnym rogu miniatury (`▶ 2m 4s`, `♪ 3m 24s`).
- **Porządkowanie:** menu widoku → **Audio i wideo** (także pod prawym klikiem): ▼ od najdłuższych/największych, ▲ od najkrótszych/najmniejszych.
- **Formaty:** MP4/M4V/M4A/MOV/3GP, MKV/WebM, AVI, WMV/WMA/ASF, Ogg/Opus, FLAC, WAV, MP3, AAC.

Wymaga Nautilusa 43+. Instalator wykrywa Fedorę, Debiana/Ubuntu, Archa i openSUSE, sam doinstalowuje pakiety i kompiluje kod.

## Instalacja

```bash
chmod +x nautilus-video-size-duration.sh
./nautilus-video-size-duration.sh                     # instalacja
./nautilus-video-size-duration.sh install --show-by-default   # kolumny w każdym folderze
./nautilus-video-size-duration.sh install --grid=video        # czas w siatce tylko na filmach (--no-grid: bez siatki)
./nautilus-video-size-duration.sh uninstall
```

Inne polecenia: `build`, `source`, `help`, `--lang pl|en`. Uruchamiaj jako zwykły użytkownik, sudo jest potrzebne tylko do pakietów i kopiowania plików.

## Karty audio bez okładki

| Format | Papier | Nuty |
|---|---|---|
| MP3 | odrobina czerwieni | Grieg, *W grotach Króla Gór*, t. 1–2 |
| WAV | ecru | Bizet, *Carmen*, Preludium, t. 1–2 (trąbka in A) |
| FLAC | odrobina szarości | Bach, I Suita wiolonczelowa, Preludium, t. 1 |
| Ogg | odrobina zieleni | Tárrega, *Gran Vals*, t. 13–15 (gitara) |
| AAC | odrobina fioletu | Ravel, *Boléro*, ostinato werbla |
| inne | kremowy | jeden takt z fermatą |

Wszystkie utwory są w domenie publicznej. Nuty *Carmen* według wydania Mutopia Project (CC BY-SA 2.5).

## Diagnostyka

```bash
nautilus -q && G_MESSAGES_DEBUG=VideoSizeDuration nautilus
```

Brak ramek w siatce: `rm -rf ~/.cache/thumbnails/*` i `nautilus -q`.

Nieobsługiwane: Nautilus 42 i starszy, systemy rpm-ostree (np. Silverblue).

---

**English:** adds sortable Duration, Width and Height columns to GNOME Files (Nautilus 43+), a duration badge on grid-view thumbnails, and ▼/▲ sort options in the view menu. Run `./nautilus-video-size-duration.sh` to install, `uninstall` to remove. Licence: EUPL-1.2.
