# Zatwierdzony zakres pierwszej wersji

> **Dokument historyczny.** Użytkownik zastąpił wariant patcha klienta pluginem i helperem odczytującym API oraz własnym DONE z `completion_seq`. Aktualny zakres: [plan implementacji](implementation-plan.md); instrukcje i stan kodu: [README](../README.md). Dawne zgody i deklaracje braku implementacji poniżej opisują wcześniejszy etap, nie obecny stan.

## Cel

Zobaczyć, że agent pracuje, skończył lub jest zablokowany, bez opuszczania aktualnej aplikacji i szukania pełnoekranowego terminala w innym Space.

## Wymagania

- Jeden mały pływający panel widoczny nad innymi aplikacjami macOS, również pełnoekranowymi, bez automatycznego przejmowania fokusu.
- Wspólna prezentacja agentów z wielu lokalnych instancji/okien Herdr, także tych połączonych ze zdalnymi maszynami.
- „Remote” oznacza lokalnego klienta Herdr połączonego ze zdalną maszyną, nie instalowanie zdalnego overlayu.
- Osobna sekcja i liczniki dla każdego lokalnego klienta Herdr, z agentami local i remote tego klienta. Sekcja odpowiada uruchomionemu klientowi Herdr, nie wykrywanemu systemowo oknu terminala.
- Nazwy agentów o statusach `blocked` i `done` stale widoczne, z oznaczeniem maszyny/projektu; nie trzeba rozwijać panelu, żeby zauważyć potrzebę uwagi.
- Używanie wyłącznie statusów dostarczanych przez Herdr: `working`, `blocked`, `done`, `idle`, `unknown`. Bez własnej detekcji i reinterpretacji.
- Odzwierciedlanie rozróżnienia `done`/`idle` z Herdr, bez własnego „przeczytane”, potwierdzania lub automatycznego ukrywania zakończonych zadań.
- Globalne włączanie i wyłączanie widoczności, z zapamiętaniem wyboru. Bez wpływu na pracę agentów.
- Rozłączone źródło musi być odróżnione od aktualnych danych; brak łączności nie jest statusem agenta.
- Użytkownik wybrał rozdzielenie statusów i liczników według klientów. Ta sama sesja oglądana w dwóch klientach występuje w obu sekcjach, zgodnie z ich własnymi statusami `done`/`idle`. Nie ma globalnego licznika unikalnych agentów ani scalania tych statusów.

## Ilustracja, nie zatwierdzony projekt wizualny

```text
HERDR 1   working 3 · blocked 1 · done 1
blocked  remote / backend · Claude
done     local / frontend · Pi

HERDR 2   working 1 · blocked 0 · done 1
done     remote / tests · Codex
```

## Zatwierdzony kierunek architektury

- Exporter jest niewielkim rozszerzeniem kodu lokalnego klienta Herdr, nie pluginem działającym przy serwerze. Udostępnia już obliczone statusy local/remote, etykiety i aktualność danych; nie otwiera własnych połączeń SSH i nie modyfikuje seen/ack.
- Jedna osobna aplikacja Swift/AppKit odbiera dane klientów i wyświetla panel. Menu w pasku macOS ma ukryj/pokaż z zapamiętaniem wyboru oraz quit bez zatrzymywania agentów.
- Komunikacja odbywa się przez lokalny read-only Unix socket: companion jest jednym listenerem, a klienci Herdr łączą się do niego po włączeniu eksportu opt-in. Tylko ten sam użytkownik, bez portu sieciowego i własnego SSH.
- Każde uruchomienie klienta ma własną tożsamość; sekcje nie wymagają rozpoznawania zewnętrznych okien Ghostty ani sterowania nimi.
- Każda aktualizacja transportu jest pełnym snapshotem zastępującym poprzedni stan danego klienta; bez odtwarzania delt. Brak odbiorcy lub wolny odbiorca nie może blokować TUI.
- Overlay pokazuje wszystkich agentów klienta, niezależnie od filtra sidebaru, ale ze statusem po klientowej projekcji `done`/`idle`. Zgodność statusów nie oznacza identycznej zawartości przefiltrowanego sidebaru.
- Po utracie połączenia z lokalnym klientem sekcja pozostaje jawnie rozłączona przez 30 sekund, po czym znika. Reconnect przywraca świeży snapshot. Stale endpoint remote wewnątrz nadal żywego klienta jest odrębnym stanem aktualności.
- Dostarczenie: najpierw izolowany lokalny patch/build Herdr bez zastępowania instalacji użytkownika. Ewentualna propozycja upstream wymaga późniejszej, osobnej zgody na publikację.
- Zgoda dotyczy kierunku projektu, nie modyfikacji instalacji użytkownika. Przegląd Claude Code oraz propozycje do rozstrzygnięcia znajdują się w `reviews/claude-architecture-review.md`.

## Poza pierwszą wersją

- Kliknięcie przenoszące do konkretnego agenta, panelu lub terminala.
- Sterowanie oknami, wybór zakładek i przełączanie Spaces.
- Własne powiadomienia lub dźwięki.
- Własne wykrywanie blokad, parsowanie ekranów i statusy z rekordów zadań MCP.
- Wymagana obsługa Linux/Windows.
- Zmiany w herdr-agent-bridge jako domyślny sposób integracji.

## Specyfikacja potwierdzona przez Claude Code

Użytkownik zatwierdził dalsze zachowanie panelu: pozycja i widoczność zapamiętywane, wszystkie pięć liczników, workspace jako projekt, bounded wysokość i przewijanie, stale poza bieżącymi licznikami i jeden wybrany monitor. Pełny dokument z kontraktem IPC, bazą Herdr, etapami wdrożenia i macierzą odbioru: [specyfikacja MVP](specs/status-overlay-design.md).

Kontrakt i etapy opisane w specyfikacji przeszły końcowy przegląd Claude Code przez MCP: ACCEPT po poprawkach. Raport: [końcowe potwierdzenie](reviews/claude-spec-review.md). To akceptacja dokumentu; implementacja, testy i podmiana instalacji nie są wykonane ani automatycznie zatwierdzone.

## Kryteria weryfikacji

- Z Safari na fullscreen widać zmiany statusów agentów lokalnych i remote bez przechodzenia do terminala.
- Aktualizacja danych nie odbiera fokusu aktywnej aplikacji.
- Statusy i liczniki odpowiadają wszystkim agentom klienta ze statusami po projekcji Herdr, także przy zmianie `done` na `idle`. Filtr sidebaru nie ukrywa agentów w overlayu i może powodować inną liczbę widocznych wierszy w samym sidebarze.
- Wyłączenie i ponowne włączenie panelu działa, a wybór jest zachowany.
- Rozłączenie, ponowne połączenie i zamknięcie klienta nie pozostawiają pozornie aktualnych danych.
- Dwa klienty oglądające tę samą sesję mają osobne sekcje i liczniki zgodne z własnym Herdr; różnice `done`/`idle` nie są scalane ani maskowane.

Zatwierdzenie zakresu nie oznacza, że wszystkie próby już wykonano. Jednorazowy panel z fikcyjnymi danymi użytkownik potwierdził jako widoczny i nieprzeszkadzający po instrukcji próby fullscreen; szczegóły i ograniczenia w `research.md`. Pozostałe kryteria nie zostały jeszcze zweryfikowane.
