# Herdr Status Overlay

Trwały podgląd statusów agentów Herdr nad aplikacjami macOS, również w pełnoekranowych Spaces.

## Problem

Użytkownik pracuje z lokalnymi agentami i agentami remote dostępnymi w lokalnych klientach Herdr. Terminal bywa otwarty na fullscreen w innym Space, a użytkownik pracuje np. w Safari. Powiadomienia macOS bywają spóźnione lub przeoczone; bez powrotu do terminala nie widać, że agent skończył albo czeka na odpowiedź.

Overlay ma być stale dostępnym widokiem aktualnej sytuacji, a nie kolejnym znikającym powiadomieniem.

## Jak to działa

Plugin Herdr `local.status-overlay` (bez zmian w Herdr) ma akcję „Status overlay: start”. Akcja otwiera w tle panel pluginu (`--no-focus`), a w nim jako proces pierwszoplanowy działa natywny helper Swift/AppKit. Helper:

- co 2 s czyta lokalną sesję: `$HERDR_BIN_PATH agent list` (socket z kontekstu pluginu);
- co 5 s (licząc od końca poprzedniego odczytu) czyta każdy alias z `machines.txt`: `$HERDR_BIN_PATH --machine <alias> agent list`;
- pokazuje jeden pływający panel szerokości 420 pt z ciemną kartą na źródło: niezerowe liczniki oraz wiersz każdego agenta: zablokowane, pracujące, zakończone, nieznane, a na końcu bezczynne. Wiersz pokazuje rodzaj agenta, katalog projektu (lub workspace) i opcjonalny tytuł aktywności; bez nagłówków trybu i przycisków;
- po kliknięciu w dowolne miejsce wiersza agenta (także bezczynnego) wywołuje `herdr [--machine <alias>] agent focus <pane_id>`, a równocześnie aktywuje Ghostty przez LaunchServices (macOS przełącza na jego Space). Przy kilku oknach Ghostty to macOS wybiera, które wyjdzie na wierzch. Dla agenta remote focus zmienia się tylko na serwerze remote; lokalny klient Herdr nie przełącza się sam na widok tej maszyny (API nie ma takiej operacji). Błąd sygnalizuje dźwiękiem.

`DONE` („skończył”) pochodzi ze statusu `done` serwera lub wykrytej zmiany `completion_seq`. Wpis znika sam po 10 minutach od wykrycia albo gdy agent znów pracuje — bez klikania i bez ack/input w Herdr (focus tylko po kliknięciu wiersza). Pierwszy odczyt (także po błędzie lub wybudzeniu) ustala punkt odniesienia dla znacznika, ale nadal pokazuje jawne `done` serwera.

Dane nieaktualne: lokalne po 6 s, remote po 20 s bez udanego odczytu, a błąd lub timeout od razu. Liczniki pokazują wtedy `—`, nagłówek karty ma dopisek „stale data”, a wiersze są szare, po 60 s cache znika (sekcja zostaje). Po wybudzeniu Maca wszystkie dane są nieaktualne do następnego odczytu.

Zamknięcie panelu pluginu, SIGHUP/SIGTERM lub „Quit overlay” w menu `HSO` kończy helper i jego odczyty. Agenci działają dalej.

## Budowanie i testy

Wymagane: macOS 13+, Swift (sprawdzono Command Line Tools ze Swift 6.4 na macOS 27, arm64). Bez zależności zewnętrznych.

```sh
swift run OverlaySelfCheck          # testy headless: fikstury i fałszywe procesy /bin/sh
swift build -c release              # helper: .build/release/HerdrStatusOverlay
sh -n bin/open-overlay bin/run-helper
```

CLT nie zawiera XCTest, dlatego testy są osobnym programem `OverlaySelfCheck` (kod wyjścia 0 = wszystko przeszło). Nie uruchamiają Herdr, SSH ani GUI.

## Konfiguracja i uruchomienie (wykonuje użytkownik)

Nic z poniższego nie jest wykonywane automatycznie.

1. `swift build -c release` w katalogu repo.
2. `herdr plugin link /ścieżka/do/herdr-status-overlay`.
3. Opcjonalnie remote: `cp examples/machines.txt "$(herdr plugin config-dir local.status-overlay)/machines.txt"` i wpisz aliasy zapisanych maszyn. Brak pliku = tylko lokalna sesja. Wymagany zapisany i włączony alias; sesje otwarte wyłącznie przez `herdr --remote` nie są widoczne.
4. W Herdr uruchom akcję „Status overlay: start” (`herdr plugin action invoke open --plugin local.status-overlay` lub paleta). Druga instancja wypisze „już działa” i się zakończy.

## Ograniczenia

- Sekcje są per źródło (lokalna sesja / alias), nie per klient Herdr; brak globalnej sumy i deduplikacji.
- Statusy pochodzą z serwera. `DONE` jest własną listą overlayu; restart serwera między dwoma udanymi odczytami bez zmiany `terminal_id` lub cofnięcia `completion_seq` nie jest wykrywany (API nie podaje epoki).
- Każdy odczyt remote uruchamia `herdr --machine`, czyli proces ssh i zdalny proces herdr. Przy wygasłym połączeniu współdzielonym może powstać nowe połączenie SSH. Helper nie ma terminala sterującego, więc ssh nie może pytać o hasło; trzeba wtedy wykonać `herdr machine reconnect`.
- Etykieta workspace to publiczne `workspace_id` (nazwy workspace nie są w odpowiedzi `agent list`).
- GUI, plugin i odczyty live nie zostały jeszcze uruchomione: zob. [testy live do wykonania](docs/pending-live-tests.md) i [backlog](docs/backlog.md). Brak testów na macOS 13 i Intel.

## Dokumenty

- [Plan implementacji — aktualny zakres](docs/implementation-plan.md)
- [Review implementacji i wykonane kontrole](docs/reviews/plugin-implementation-review.md)
- [Backlog](docs/backlog.md) i [testy live do wykonania](docs/pending-live-tests.md)
- [Specyfikacja exportera — historyczna; aktualna tylko §8 (panel)](docs/specs/status-overlay-design.md)
- [Historyczny zakres](docs/scope.md), [research](docs/research.md)
- Przeglądy Claude Code: [architektura](docs/reviews/claude-architecture-review.md), [specyfikacja](docs/reviews/claude-spec-review.md)
