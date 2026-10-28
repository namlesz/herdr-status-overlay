# Herdr Status Overlay

Plugin Herdr (`local.status-overlay`, macOS) z natywnym pływającym panelem statusów agentów — lokalnych i z zapisanych maszyn remote. Panel pływa nad innymi aplikacjami na wszystkich Spaces, także pełnoekranowych, więc nie trzeba wracać do terminala, żeby zobaczyć, że agent skończył albo czeka.

## Instalacja

Wymagane: macOS 13+, Swift (Command Line Tools wystarczą), Herdr ≥ 0.9.5, Ghostty. Bez zależności zewnętrznych.

```sh
swift build -c release                         # helper: .build/release/HerdrStatusOverlay
herdr plugin link /ścieżka/do/herdr-status-overlay
```

Maszyny remote (opcjonalnie): skopiuj `examples/machines.txt` do `$(herdr plugin config-dir local.status-overlay)/machines.txt` i wpisz aliasy zapisanych maszyn (`herdr machine list`), po jednym w wierszu, `#` to komentarz, maksymalnie 16. Brak pliku oznacza tylko sesję lokalną. Sesje otwarte wyłącznie przez `herdr --remote` nie są widoczne. Plik jest czytany przy starcie helpera.

Start: automatycznie po uruchomieniu serwera Herdr i odtworzeniu sesji (także po aktualizacji z przekazaniem sesji nowemu serwerowi). Hook `[[startup]]` uruchamia helper jako proces w tle, bez terminala, zakładki i zmiany fokusu. Samo podłączenie klienta, przeładowanie konfiguracji, podlinkowanie lub włączenie pluginu nie uruchamia hooka. W już działającej sesji użyj akcji „Status overlay: start” z palety Herdr albo `herdr plugin action invoke open --plugin local.status-overlay`. Druga instancja wypisze „już działa” i się zakończy. Diagnostyka trafia do `$HERDR_PLUGIN_STATE_DIR/helper.log`.

Stop: zakończenie procesu serwera Herdr (także awaria), „Quit overlay” w menu `HSO` na pasku menu albo SIGTERM. Helper obserwuje PID serwera przekazany przez skrypt startowy i kończy swoje odczyty; ręczne zatrzymanie overlayu nie zatrzymuje agentów. Samo odłączenie klienta Herdr nie kończy overlayu. Nie ma nadzoru ani automatycznego ponawiania po awarii helpera lub ręcznym zamknięciu — do następnego startu serwera uruchom go ponownie akcją pluginu. Przy przekazaniu sesji nowemu serwerowi jego hook uruchamia nowy helper; czeka do 10 s na zwolnienie blokady przez poprzednią instancję.

## Działanie

**Odczyty.** Helper wywołuje `$HERDR_BIN_PATH agent list` (sesja lokalna, 2 s po końcu poprzedniego odczytu) i `$HERDR_BIN_PATH --machine <alias> agent list` (każdy alias, 5 s po końcu poprzedniego). Na źródło działa najwyżej jeden proces naraz. Timeout wynosi 10 s, a stdout jest ograniczony do 1 MiB. Treść stderr jest odrzucana. Po błędzie kolejne próby następują co 5, 10, a potem 30 s. Proces nie ma terminala sterującego, a stdin to `/dev/null`, więc ssh nie może pytać o hasło.

**Panel.** Na każde źródło jest jedna ciemna karta z niezerowymi licznikami i wierszem każdego agenta. Kolejność: zablokowane, pracujące, zakończone (`done`), nieznane, bezczynne. Wiersz pokazuje rodzaj agenta, katalog projektu (lub `workspace_id`) i opcjonalny tytuł terminala. Panel ma 420 pt szerokości i najwyżej 40% wysokości ekranu, dalej się przewija. Można go przeciągać. Pozycja i widoczność są zapisywane w `$HERDR_PLUGIN_STATE_DIR/panel.json`, a po odłączeniu monitora panel wraca na widoczny ekran. Menu `HSO` pozwala go ukryć lub pokazać. Interfejs jest po angielsku i używa JetBrains Mono, jeśli ten font jest zainstalowany.

**Zwijanie.** Strzałka w nagłówku pierwszej karty zwija panel do małego, przeciąganego paska. Pokazuje on wyłącznie niezerowe sumy: ● pracujący, ⚠ zablokowani, ✓ zakończeni (`done`), ze wszystkich świeżych źródeł. Bezczynni i nieznani są pomijani. Przy braku aktywnych jest „No active agents”, a bez świeżych danych „—”. Liczniki nie deduplikują agentów między źródłami. Strzałka na pasku przywraca pełną listę; wybrany tryb jest zapisywany w `panel.json`.

**Auto-hide.** Opcja „Auto-hide” w menu `HSO` zostawia na ekranie pieska z kreskówkowym dymkiem przy piesku, zawierającym te same liczniki co tryb zminimalizowany, bez strzałki. Dymek ma falowany obrys chmurki, dwa bąbelki prowadzące do pieska, białe tło o kryciu 22% i cieniowane napisy; przy systemowym Reduce Transparency jest biały z ciemnymi napisami. Szerokość dymka dopasowuje się do widocznych liczników (bez zmiany rozmiaru tekstu). Gdy świeże źródła nie mają aktywnych agentów, dymek znika i zostaje sam piesek; brak świeżych danych nadal pokazuje „—”. Najazd na pieska lub dymek rozwija pełną listę bez przejmowania fokusu; opuszczenie panelu chowa ją po około 0,4 s. Powrót kursora anuluje chowanie. Piesek pozostaje na miejscu: tryb rezerwuje przestrzeń na rozwinięcie w wybranym kierunku, dlatego blisko krawędzi ekranu pozycja może być korygowana. Ustawienie jest zapisywane w `panel.json`, domyślnie wyłączone; po wyłączeniu wraca wcześniejszy tryb ręczny.

**Kierunek panelu.** Menu `HSO → Panel position` wybiera położenie listy i dymka względem pieska: Top left (domyślne), Top right, Bottom left lub Bottom right. W Auto-hide dymek jest odsunięty po przekątnej na wybraną stronę pieska, także przy jednym liczniku. Zmiana zachowuje pozycję pieska, o ile układ mieści się na ekranie. Wybór działa także w ręcznym trybie i jest zapisywany w `panel.json`; starsze ustawienia zachowują dotychczasowy kierunek.

**Maskotka.** Kreskówkowy jasny piesek ze zdjęcia (96 pt, bez szelek i smyczy) pokazuje stan przy dymku ze zwiniętymi licznikami i w rogu rozwiniętego panelu zgodnym z wybranym kierunkiem, poza przewijanymi kartami. Śpi przy bezczynnych agentach z unoszącymi się literami „z”, „z”, „Z”. Podczas pracy cyklicznie biegnie w miejscu (4 s), węszy (2 s), pluska się w basenie, wykopuje kość, szarpie zabawkę, tarza się i aportuje piłkę (każda zabawa po 4 s). Przy blokadzie stoi ze znakiem **STOP**, delikatnie porusza głową i ogonem oraz mruga; blokada przerywa pracę i świętowanie. Przy braku świeżych danych przekrzywia głowę, a po nowym zakończeniu świętuje przez 3 s. macOS Reduce Motion pokazuje nieruchomą pozę (podczas pracy stojącą, przy blokadzie ze STOP); gdy panel jest ukryty, animacja nie działa. Pozycja i rozmiar maskotki nie zmieniają się. Klatki w `Sources/OverlayApp/Resources/Corgi` generuje `swift scripts/prepare-corgi-assets.swift` z arkuszy w `Art/dog`; nazwy skryptu i katalogu zasobów pozostają historyczne. Zatwierdzony wzór i opis arkuszy: `Art/dog/`.

**Kliknięcie wiersza** aktywuje Ghostty (macOS przełącza na jego Space) i wywołuje `herdr [--machine <alias>] agent focus <pane_id>`. Błąd sygnalizuje dźwiękiem.

**`done`.** Agent ma status `done`, gdy serwer zgłasza `done` albo gdy overlay wykryje wzrost `completion_seq`. Po 10 minutach oznaczenie przechodzi w bezczynny; gdy agent znów pracuje, od razu wraca status pracujący (zablokowany i nieznany też mają pierwszeństwo przed `done`). Pierwszy odczyt, także po błędzie lub wybudzeniu Maca, ustala punkt odniesienia `completion_seq`, więc nie tworzy fałszywych zakończeń, ale jawne `done` serwera pokazuje. Stan jest wyłącznie w pamięci.

**Nieaktualne dane.** Dane lokalne stają się nieaktualne po 6 s bez udanego odczytu, remote po 20 s, a przy błędzie lub po wybudzeniu od razu. Karta remote jest ukryta, dopóki nie nadejdzie udany, świeży odczyt; pozostałe źródła działają dalej. Pusty panel jest automatycznie ukrywany bez zmiany zapisanej preferencji widoczności. Lokalna karta pozostaje: liczniki pokazują `—`, karta ma dopisek „stale data”, a wiersze są szare. Po 60 s od ostatniego udanego odczytu lista agentów znika z pamięci.

## Ograniczenia

- Karty są per źródło (sesja lokalna / alias), nie per klient Herdr. Pełny widok nie sumuje źródeł; żaden widok nie deduplikuje agentów między źródłami.
- API nie podaje epoki serwera. Restart serwera między dwoma udanymi odczytami jest wykrywany tylko po nowym `terminal_id` lub spadku `completion_seq`.
- Przy kilku oknach Ghostty to macOS wybiera, które wyjdzie na wierzch. Focus agenta remote zmienia się na serwerze remote; lokalny klient Herdr nie przełącza się sam na widok tej maszyny.
- Każdy odczyt remote to proces ssh i zdalny `herdr`. Błąd odczytu ukrywa kartę bez rozróżnienia przyczyny. Jeśli połączenia nie da się odnowić bez hasła, wykonaj `herdr machine reconnect`.
- Etykieta miejsca to katalog roboczy albo `workspace_id`; nazw workspace nie ma w odpowiedzi `agent list`.
- Nie testowano na macOS 13, Intel ani z VoiceOver.

## Rozwój

```sh
swift run OverlaySelfCheck   # testy headless (kod wyjścia 0 = OK)
swift scripts/check-overlay-launch.swift  # start w tle na fiksturze, bez Herdr i GUI
sh scripts/check-overlay-layout.sh  # AppKit: zwijanie, paski przewijania, przesuwanie przy krawędziach; okno ukryte
```

Command Line Tools nie zawierają XCTest, dlatego testy są osobnym programem. Używają fikstur i fałszywych procesów `/bin/sh`, bez Herdr, SSH ani GUI.

- `Sources/OverlayCore`: parser `agent list`, wykrywanie zakończeń, stan źródeł, pętle odczytu, uruchamianie procesów.
- `Sources/OverlayApp`: AppKit (panel, menu `HSO`, kliknięcie wiersza) i punkt wejścia helpera.
- `Sources/OverlaySelfCheck`: testy.
- `bin/`: skrypty startu procesu w tle z `herdr-plugin.toml`.
