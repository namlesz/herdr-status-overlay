# Końcowe potwierdzenie specyfikacji przez Claude Code

## Wynik

**ACCEPT — dokument.** Specyfikacja: [status-overlay-design.md](../specs/status-overlay-design.md).

Przegląd przeprowadzono przez MCP Herdr (`herdr-agent-bridge`) w jednorazowym procesie Claude Code. Po odebraniu i zweryfikowaniu raportów agent, jego panel i sesja MCP zostały zamknięte. Nie użyto subagenta Pi do tego potwierdzenia.

To akceptacja spójności i kompletności projektu, nie dowód działania implementacji ani zgoda na jej rozpoczęcie.

## Przebieg

| Zadanie MCP | Werdykt | Zakres |
| --- | --- | --- |
| `t_20a5ac940d874fa1` / confirm-overlay-spec | ACCEPT WITH FIXES | Pełny przegląd specyfikacji, sześć poprawek M1–M6. |
| `t_e824e68060685fbb` / confirm-overlay-spec-fixes | ACCEPT WITH FIXES | Potwierdzono wszystkie M1–M6; wskazano bramkę zgodności F1 przed integracją na istniejących sesjach. |
| `t_1fc5ac73ba5e0a7a` / confirm-final-compatibility-gate | ACCEPT | Ostatni, wąski odczyt bramki §9, etapu 4 i A15; F1 domknięte, brak blockerów. |

Ostatni raport nie był kolejnym pełnym przeglądem od zera. Werdykt końcowy opiera się na całym powyższym przebiegu.

## Uwzględnione poprawki

- M1: normalizacja i bezpieczne przycinanie etykiet przez exporter; bez zmiany identyfikatorów i bez rozłączania całego klienta z powodu zwykłej nazwy workspace. Walidacja odbiorcy pozostaje aktywna.
- M2: companion bez App Sandbox, obie strony używają dokładnie `confstr(_CS_DARWIN_USER_TEMP_DIR)` zamiast środowiskowego `TMPDIR` lub katalogu kontenera.
- M3: `SO_NOSIGPIPE` na sockecie exportera; `EPIPE` nie może zakończyć TUI i nie zmienia się globalnej dyspozycji sygnału.
- M4: config testowego klienta przez procesowy `HERDR_CONFIG_PATH`, bez modyfikacji zwykłej konfiguracji. Opt-in czytane przy starcie; zmiana wymaga restartu samego klienta, nie agentów/serwera.
- M5: po connect odrzucany stary bufor, pierwsza próbka pobierana po connect. Przyszły lub malejący czas próbki jest błędem; stare połączenie nie może nadpisać/rozłączyć następcy.
- M6: kryterium A14 obejmuje opt-in i izolację konfiguracji.
- F1: przed etapem 4 wyłącznie odczytem potwierdza się zgodność protokołu z rzeczywistymi serwerami local/remote. Brak dowodu lub niezgodność zatrzymuje integrację. Zakaz aktualizacji/restartu/stop/handoffu serwerów użytkownika; nowe środowisko/SSH wymaga osobnego uzgodnienia. Kryterium A15.

Dodatkowo doprecyzowano typy pól, timery poza UI, ograniczenie kolejek po obu stronach, testy framing/reconnect/limitów, brak ogłoszeń VoiceOver dla niezmienionych heartbeatów oraz reconnect do 5 s z resetem backoffu dopiero po utrzymanym połączeniu.

## Weryfikacja koordynatora

- Odczytano wskazane fragmenty SDK macOS: `sys/socket.h` potwierdza `SO_NOSIGPIPE`, `unistd.h` potwierdza `_CS_DARWIN_USER_TEMP_DIR`.
- `herdr --help` potwierdza `HERDR_CONFIG_PATH`; nie zmieniano konfiguracji.
- Odczytano upstream `5608de0608918aba2f9d501e7793b984a0ca9cfa`: `src/platform/unix_common.rs:421–426` zmienia dyspozycję SIGPIPE przy CLI output. Nie zakładamy, że całe TUI zawsze działa z SIG_DFL.
- Odczytano `src/server/client_transport.rs:740–778` i `src/cli/target.rs:165–184`: odmowa przy niezgodnych generation/codecs i ostrzeżenie, że zatrzymanie serwera kończy procesy paneli. To uzasadnia F1; nie dowodzi zgodności konkretnych serwerów użytkownika.
- Przykład JSON parsuje się; kryteria A1–A15 są kompletne i bez duplikatów; odnośniki lokalne sprawdzone.

## Ograniczenia

Nie wykonano implementacji, testów protokołu, buildów produktu, testów opóźnień/backpressure, sleep/wake, multi-monitor ani zgodności live local/remote. Wcześniejsza ręczna obserwacja jednorazowego panelu nad fullscreen dotyczyła wyłącznie fikcyjnych danych.

Opcjonalne drobne uwagi z review nie blokują projektu; szczegóły fallbacków etykiet i walidacji w implementacji muszą pozostać zgodne z kontraktem i testami. Kolejnym etapem może być implementacja dopiero po osobnej zgodzie użytkownika.
