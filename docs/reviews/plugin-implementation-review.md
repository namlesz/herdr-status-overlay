# Implementacja pluginu — weryfikacja i review

## Aktualny wariant

Plugin `local.status-overlay` uruchamia foreground helper Swift/AppKit w swojej zakładce Herdr. Bez patcha, przebudowy ani podmiany Herdr. Dane: lokalne API i jawnie skonfigurowane zapisane maszyny przez `--machine`. Własna lista DONE ze znacznika `completion_seq`, bez modyfikowania klientowego seen/ack.

Zakres i ograniczenia: [plan](../implementation-plan.md), [backlog](../backlog.md), [niewykonane testy live](../pending-live-tests.md).

## Wykonanie i kontrole

Claude Code przez MCP zaimplementował rdzeń, helper, manifest, skrypty i self-check. Zgłosił 89/89 kontroli oraz udane buildy debug/release. Koordynator odczytał kod i samodzielnie powtórzył te sprawdzenia.

Niezależny reviewer w osobnej sesji read-only przejrzał całość kodu produktu. Wskazał:

1. Wyścig anulowania: sygnał mógł zostać wysłany do numeru grupy po zwolnieniu PID.
2. Zamknięcie stdout/stderr mogło przedwcześnie zabić nadal pracujące dziecko.
3. Pierwszy znacznik na pierwszej próbce working mógł stworzyć fałszywe DONE.
4. Zmiana monitora lub rozdzielczości nie utrzymywała limitu 40% wysokości panelu.

Koordynator potwierdził przyczyny w kodzie. Dodał trzy regresje logiki/procesów, które przed poprawkami zakończyły się wynikiem 89/92 (wszystkie trzy nowe kontrole niezaliczone). Po zmianach synchronizacji, nadzoru procesu i baseline: 92/92.

Dodano czyste obliczenie geometrii wraz z trzema kontrolami bez AppKit; ograniczono dostarczanie modelu UI do jednego najnowszego stanu i jednego oczekującego callbacku; wybudzenie omija stary interwał/backoff pollera. Łącznie self-check ma 101 kontroli.

## Wynik po poprawkach

Koordynator wykonał na macOS 27 arm64, Swift 6.4 CLT:

- `swift build` — exit 0.
- `swift run OverlaySelfCheck` — **101/101**, exit 0.
- `swift build -c release` — exit 0.
- `.build/release/OverlaySelfCheck` — **101/101**, exit 0.
- `sh -n bin/open-overlay` i `sh -n bin/run-helper` — exit 0.
- `vtool -show-build .build/release/HerdrStatusOverlay` — MACOS, minos **13.0**.
- Czysty build w oddzielnym katalogu: `swift build --build-system native --scratch-path .build/native-verification` — exit 0; `swift run --build-system native --scratch-path .build/native-verification OverlaySelfCheck` — **101/101**, exit 0. Ten tryb kontrolny jest deprecated w Swift 6.4; normalne komendy produktu pozostają bez `--build-system`.

Kolejne niezależne review read-only poprawek nie znalazło potwierdzonych usterek ani blockerów w przeglądanym zakresie. Reviewer nie wykonywał testów; powyższe wyniki pochodzą od koordynatora.

Linker zgłasza ostrzeżenia o brakujących katalogach `Developer/usr/lib` i `Developer/Library/Frameworks` lokalnego CLT, mimo poprawnego zakończenia buildów. SourceKit po przebudowie nadal raportował dwa błędy „SourcePoller has no member refresh”, choć metoda jest w aktualnym źródle i oba targety z jej wywołaniem kompilują się; nie deklarujemy czystego LSP.

## Granice dowodów

Self-check używa wyłącznie danych fikcyjnych i procesów testowych `/bin/sh`. Nie instaluje pluginu, nie uruchamia Herdr/SSH ani GUI. Wcześniejsze odczyty prawdziwego API i próby completion są dowodem formatu/transportu, nie odbiorem helpera.

Nie wykonano instalacji/linku pluginu, próby GUI, VoiceOver, fullscreen, monitorów, sleep/wake ani pracy helpera na local/remote. Target 13.0 nie jest dowodem działania na macOS 13 lub Intel. Nie zmieniano instalacji Herdr, serwerów, konfiguracji MCP ani zdalnych agentów w ramach implementacji. Bez commitów i publikacji.
