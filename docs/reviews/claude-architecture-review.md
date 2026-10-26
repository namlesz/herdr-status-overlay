# Przegląd architektury przez Claude Code

## Pochodzenie i zakres

Przegląd wykonany przez Claude Code uruchomionego w Herdr przez MCP `herdr-agent-bridge`, nie przez subagenta Pi. Zadanie: `overlay-architecture-review`, tryb read-only. Agent tymczasowy zakończony, jego panel i sesja bridge zamknięte po odebraniu i weryfikacji raportu.

Przeczytane przez recenzenta: README, scope, research oraz wybrane fragmenty upstream Herdr `5608de0`. Nie wykonywano testów, buildów, połączeń SSH ani zmian w repo. Brak commitów/HEAD w tym repo jest oczekiwany. Koordynator ponownie sprawdził stan plików i wskazane miejsce stosowania filtrów klienta.

To raport z przeglądu i propozycje, nie zatwierdzona kompletna specyfikacja ani zgoda na implementację.

## Werdykt

Kierunek jest minimalny i spójny z problemem: eksport istniejących statusów z lokalnych klientów Herdr, jeden natywny companion macOS, lokalne read-only Unix sockets oraz osobne sekcje/liczniki per klient. Nie należy wracać do globalnej deduplikacji lub własnych statusów.

Przed implementacją trzeba doprecyzować kontrakt danych, kierunek połączenia, aktualność źródeł i nieblokowanie TUI.

## Najważniejsze uwagi

1. **Discovery i kierunek IPC.** Rekomendacja Claude: jeden listener w companionie, klienci Herdr łączą się do niego. Eliminuje socket per klient i skanowanie katalogu. Exporter opt-in w konfiguracji Herdr; nieobecność lub awaria companiona nie może wpływać na TUI. Ta konkretyzacja wymaga zatwierdzenia.
2. **Pełne snapshoty zamiast delt.** Każda aktualizacja zastępuje całą projekcję klienta. Po reconnect pierwszy pełny snapshot; unikamy odtwarzania zdarzeń i brakujących granic sekwencji. NDJSON, jawna wersja protokołu, limit wiadomości, heartbeat. Konkretne wartości wymagają ustalenia.
3. **Nieblokowanie klienta.** Osobny task/wątek transportu, ograniczony bufor najnowszego snapshotu i koalescencja. Wolny lub nieobecny odbiorca nie może zatrzymać renderowania ani rozbudować kolejki bez limitu. Snapshot aktualnie wysyłany musi zostać ukończony lub połączenie zerwane; nie wolno mieszać jego bajtów z nowszym snapshotem.
4. **Filtry a kompletność.** Aktywny widok sidebaru filtruje agentów (`src/client/shell/aggregate_navigation.rs:109–114`). Rekomendacja: eksport wszystkich agentów z połączonych endpointów przed filtrem sidebaru, ale po klientowej projekcji statusów `done`/`idle`. Dzięki temu filtr sidebaru nie ukryje agenta wymagającego uwagi w overlayu. Jest to decyzja produktowa do zatwierdzenia.
5. **Trzy osobne poziomy stanu.** Połączenie z lokalnym klientem, aktualność jego endpointu remote/local i status agenta to różne informacje. Nie zamieniać rozłączenia w nowy status agenta. Ustalić czas pokazywania sekcji zamkniętego/rozłączonego klienta i sposób prezentacji cache.
6. **Minimalna allowlista.** Identyfikatory klienta/endpointu/panelu, status, etykieta agenta, maszyny i workspace oraz aktualność. Bez automatycznego serializowania całych struktur Herdr. Rekomendacja: bez treści ekranów, komend, cwd i tytułów terminala; projekt identyfikować etykietą workspace. Do uzgodnienia.

## Zabezpieczenia kontraktu IPC

- Katalog użytkownika `0700`, socket `0600`, weryfikacja UID partnera. Bez portów TCP i bez zdalnego listenera.
- Krótka ścieżka socketu; walidacja rzeczywistej długości adresu macOS. Nie zakładać, że dowolny `$TMPDIR` lub ścieżka pod katalogiem domowym się zmieści.
- Jedna instancja companiona. Sprzątanie starego socketu wymaga sprawdzenia właściciela, typu wpisu, dowiązań oraz konkurencyjnego startu. Sama nieudana próba connect nie jest wystarczającą podstawą do bezwarunkowego unlink.
- IPC tylko z danymi do wyświetlenia, bez komend focus, input lub seen/ack.
- Niekompatybilna wersja powinna być zgłoszona, nie zgadywana.

## Doprecyzowania i ograniczenia oceny

- Recenzent nazwał kierunek z exporterem jedynym wiernym rozwiązaniem. Odczyt kodu uzasadnia go wśród rozważanych wariantów; nie jest dowodem braku wszystkich innych możliwych integracji.
- Sama nazwa/etykieta to także potencjalnie prywatna informacja. Ograniczenia pól zmniejszają zakres eksportu, nie zapewniają braku danych wrażliwych.
- Recenzent potraktował sleep/wake jako szczegół implementacji. Dla celu produktu utrata aktualności po uśpieniu i poprawny reconnect muszą być sprawdzone w kryteriach odbioru.
- Obecność endpointowej projekcji potwierdzono w `5608de0`, nie we wszystkich wydaniach Herdr. Przed implementacją trzeba ustalić docelowy bazowy commit/wydanie i sposób dostarczenia poprawki (lokalny fork lub upstream).
- Przegląd nie zastępuje testu opóźnień statusów, backpressure, reconnect, bezpieczeństwa IPC, pełnej obsługi fullscreen i wielu monitorów.

## Pytania wymagające decyzji

1. Jeden listener w companionie i klienci jako nadawcy, z exporterem opt-in?
2. Wszyscy agenci klienta czy tylko aktywny filtr sidebaru?
3. Po zamknięciu/utracie klienta: usunięcie sekcji czy krótki jawnie rozłączony stan?
4. Czy etykieta workspace wystarczy jako „projekt”, bez eksportowania cwd i tytułów terminala?
5. Docelowa baza Herdr i tryb dostarczenia zmiany: lokalny fork czy propozycja upstream?

## Minimalne testy wynikające z przeglądu

- Statusy po projekcji i brak mutacji seen/ack; dwa klienty mogą zgodnie pokazywać różne `done`/`idle`.
- Wszystkie dozwolone statusy oraz zdecydowana polityka filtrów i cache w licznikach.
- Start aplikacji przed/po klientach, restart aplikacji i Herdr, zamknięcie klienta, EOF oraz zawieszone połączenie.
- Remote offline/reconnect i sleep/wake: cache nigdy nie udaje aktualnego stanu.
- Wolny odbiorca, zerwane połączenie w połowie wiadomości i lawina zmian: TUI działa, pamięć i bufory są ograniczone.
- Zła wersja, uszkodzona/przerośnięta wiadomość, nieprawidłowy UID, stary socket i konkurencyjny start aplikacji.
- Trwałe hide/show, quit bez zatrzymania agentów i panel bez przejmowania fokusu nad fullscreen.
