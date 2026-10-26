# Herdr Status Overlay — specyfikacja MVP

> **Dokument historyczny.** Użytkownik zastąpił wariant patcha klienta pluginem i helperem odczytującym API oraz własnym DONE z `completion_seq`. Aktualny zakres: [plan implementacji](../implementation-plan.md); instrukcje i stan kodu: [README](../../README.md). Dawne zgody i deklaracje braku implementacji poniżej opisują wcześniejszy etap, nie obecny stan.

Status: zakres, architektura i zachowanie zatwierdzone przez użytkownika; dokument potwierdzony przez Claude Code przez MCP jako ACCEPT po poprawkach M1–M6 i bramce F1. Raport: [końcowy przegląd](../reviews/claude-spec-review.md). To akceptacja projektu, nie wynik testów implementacji ani zgoda na jej rozpoczęcie, podmianę instalacji lub publikację.

## 1. Problem i cel

Użytkownik korzysta z lokalnych klientów Herdr z agentami local i remote. Terminal jest często na fullscreen w innym Space, podczas gdy użytkownik pracuje np. w Safari. Powiadomienie macOS może się spóźnić lub zostać przeoczone. Potrzebny jest trwały podgląd: kto pracuje, kto czeka i kto skończył, bez opuszczania bieżącej aplikacji.

Remote oznacza zdalną maszynę już obsługiwaną przez lokalnego klienta Herdr. Overlay nie otwiera własnych połączeń SSH i nie jest instalowany na zdalnej maszynie.

## 2. Zakres zatwierdzony przez użytkownika

- Jeden natywny pływający panel nad innymi aplikacjami, także fullscreen, bez automatycznego przejmowania fokusu.
- Jedna aplikacja macOS z osobnymi sekcjami i licznikami dla każdego uruchomionego lokalnego klienta Herdr. Klient nie oznacza systemowego okna Ghostty.
- W każdej sekcji wszyscy agenci endpointów tego klienta, niezależnie od aktywnego filtra sidebaru, ze statusami już obliczonymi przez klienta Herdr.
- Dokładnie statusy `working`, `blocked`, `done`, `idle`, `unknown`. Bez własnej detekcji i reinterpretacji `done`/`idle`.
- Liczniki wszystkich pięciu statusów; poniżej nazwane wiersze `blocked`, następnie `done`, z etykietą maszyny i workspace jako projektu.
- Ta sama sesja oglądana w dwóch klientach występuje w obu sekcjach. Brak globalnego sumowania i deduplikacji; różne `done`/`idle` mogą być poprawne dla różnych klientów.
- Zapamiętanie widoczności i pozycji panelu. Menu ukryj/pokaż i quit; bez zatrzymywania agentów.
- Nieaktualne dane opisane i przygaszone, nie wchodzą do bieżących liczników.
- Utracony lokalny klient: sekcja jawnie rozłączona przez 30 sekund, potem usunięta. Reconnect przywraca pełny świeży stan.
- Jeden panel na wybranym monitorze; bez powielania na wszystkich ekranach. Ograniczona wysokość i przewijanie przy wielu wierszach.
- Najpierw izolowany lokalny patch/build Herdr bez podmieniania instalacji. Ewentualne zgłoszenie upstream wymaga osobnej zgody.

Poza MVP: przechodzenie do agenta, sterowanie oknami/Spaces, własne powiadomienia i dźwięki, własne statusy/ack, ekrany terminali, eksport komend/cwd, sieciowy listener, własne SSH, globalny hotkey, autostart przy logowaniu, telemetria oraz wymagane Linux/Windows. Plugin nie jest procesem nadzorującym helper i nie jest potrzebny do pierwszej wersji.

## 3. Architektura

```text
klient Herdr A — opt-in exporter ──┐
                                  ├─ Unix socket → companion Swift/AppKit → jeden NSPanel
klient Herdr B — opt-in exporter ──┘
```

Companion jest jedynym listenerem. Każdy exporter jest nadawcą pełnego stanu swojego klienta. Dane płyną tylko Herdr → companion. Brak komend do zmiany fokusu, input, uruchamiania agentów i potwierdzania obejrzenia.

### Exporter w Herdr

- Niewielka zmiana kodu lokalnego klienta, nie hook/plugin przy serwerze. Domyślnie wyłączona; jawne `status_overlay.enabled = true` odczytywane tylko przy starcie lokalnego klienta. W MVP zmiana tej opcji wymaga ponownego uruchomienia samego klienta, nie serwera ani agentów; zamknięcie poprzedniego klienta kończy jego transport. Konfiguracja remote i zwykły reload serwera nie włączają eksportu.
- Pobiera wszystkich agentów z gotowych snapshotów endpointów po projekcji klientowego `done`/`idle`, ale przed filtrem aktywnego widoku sidebaru.
- Nie wywołuje ack/seen, nie żąda powierzchni terminala i nie wpływa na wybór maszyny, workspace ani panelu.
- Statusy i zmiany connectivity/etykiet unieważniają projekcję eksportu. Odbiornik jest powiadamiany po zastosowaniu aktualizacji stanu klienta; sam eksport nie uruchamia ponownej detekcji.
- Gdy companion nie działa, klient wykonuje wyłącznie ograniczone próby lokalnego połączenia z backoffem; praca Herdr jest niezależna od wyniku.

### Companion

- Aplikacja `.app`, Swift/AppKit, polityka `.accessory`, bez ikony Dock i bez App Sandbox. Własny cykl życia, niezależny od Herdr. Niesandboxowany lokalny build używa wspólnej systemowej ścieżki runtime, nie katalogu kontenera.
- Jeden listener Unix, wielokrotne połączenia klientów, jeden panel. Dekodowanie i odczyt poza głównym wątkiem; podmiana modelu UI na głównym wątku.
- Także po stronie odbiorcy najwyżej jeden oczekujący model/snapshot na klienta; UI otrzymuje najnowszy stan, nie nieograniczoną kolejkę callbacków. Odczyt i dekodowanie nie blokują głównego wątku.
- Ukrycie panelu nie zamyka listenera ani nie przerywa odbioru. Ponowne pokazanie używa aktualnego stanu. Quit zamyka połączenia i listener; agenci nadal pracują.
- Brak zapisu snapshotów na dysk. Trwale przechowywane są tylko widoczność i pozycja panelu.

## 4. Tożsamość i allowlista danych

Każde uruchomienie klienta tworzy losowy 128-bitowy `client_id`, stały przez reconnecty, nowy po restarcie procesu. Nie jest to ID serwera ani okna systemowego. Etykieta klienta to etykieta lokalnej sesji i krótki fragment `client_id`; fallback: `Herdr` i krótki ID. Dzięki temu sekcje są rozróżnialne bez API zewnętrznego terminala.

Klucze: sekcja = `client_id`; endpoint = `(client_id, endpoint_id)`; agent = `(client_id, endpoint_id, pane_id)`. Nie scalać profili SSH, aliasów ani klientów. Usunięcie starego endpointu lub agenta z pełnego snapshotu usuwa go z bieżącego stanu.

Dozwolone pola:

| Poziom | Pola |
| --- | --- |
| Wiadomość | `v`: int równy 1; `client_id`: UUID w małych literach z myślnikami; `client_label`: string; `sampled_at_ns`: u64; `endpoints`: array |
| Endpoint | `endpoint_id`, `machine_label`: string; `stale`: bool; `agents`: array |
| Agent | `pane_id`, `workspace_label`, `agent_label`: string; `status`: enum string v1 |

`stale` pochodzi z natywnego stanu połączenia endpointu Herdr. Brak używalnego snapshotu endpointu oznacza pustą listę agentów i `stale: true`, nie pięć zer udających potwierdzony brak pracy. Projekcja może zachować cache remote wraz z `stale: true`.

`sampled_at_ns` to moment pobrania projekcji z aktywnego stanu lokalnego klienta, w nanosekundach wspólnego dla procesów tego Maca zegara `mach_continuous_time` po konwersji przez systemowy timebase. Nie jest to czas zdarzenia na remote. Odbiorca mierzy wiek próbki tym samym zegarem; nie porównuje prywatnych epok zegarów bibliotek ani czasu ściennego. Przyszły timestamp lub wiek ponad 6 s nie przywraca aktualności.

`agent_label`: istniejąca jawna nazwa agenta, następnie jego typ, następnie `pane_id`. `workspace_label`: istniejąca etykieta workspace; fallback to jego publiczny identyfikator. Exporter zamienia C0, DEL i C1 (U+0000–001F, U+007F–009F) oraz separatory linii U+2028/U+2029 na spacje, usuwa nadmiarowe odstępy i przycina etykiety do 1024 bajtów na granicy znaku UTF-8. Pusta etykieta używa opisanych fallbacków. Identyfikatorów nie przycina ani nie zmienia. Walidacja odbiorcy nadal odrzuca niepoprawne etykiety jako błąd nadawcy. Nie eksportować dodatkowo cwd, tytułów terminala, ekranów, promptów, komend, tokenów ani danych sesji agenta. Same etykiety też mogą zawierać prywatne treści; nie zapisywać ich w logach ani wysyłać poza lokalny kanał.

## 5. Protokół IPC v1

Każda wiadomość jest kompletnym snapshotem klienta: UTF-8 JSON w jednej linii zakończonej LF (NDJSON). Po połączeniu pierwszą wiadomością jest snapshot, bez osobnego hello i bez żądań sterujących. Nowy snapshot atomowo zastępuje poprzedni stan tego klienta. Bez delt, replay, bazy danych i sekwencjonowania zdarzeń.

Przykład danych fikcyjnych:

```json
{"v":1,"client_id":"b90b2281-ec45-4870-a4de-fcaef2379af3","client_label":"dev · b90b2281","sampled_at_ns":123456789000,"endpoints":[{"endpoint_id":"local","machine_label":"Local","stale":false,"agents":[{"pane_id":"w1:p2","workspace_label":"backend","agent_label":"Claude","status":"blocked"}]}]}
```

### Wysyłanie i backpressure

- Zmiany są koalescowane; po zmianie stanu najnowsza projekcja trafia do transportu w czasie do 100 ms w normalnych warunkach.
- Serializacja i I/O działają w osobnym tasku/wątku. Bufor oczekujący przechowuje najwyżej jeden najnowszy snapshot, zastępowany bez oczekiwania na czytelnika.
- Wiadomość rozpoczęta musi być dokończona albo połączenie zerwane. Nie wolno wstawić nowego snapshotu w środek starej linii.
- Timeout pełnego zapisu: 1 s. Socket exportera ma `SO_NOSIGPIPE` ustawione przed pierwszym zapisem; nie zmieniamy globalnej dyspozycji sygnału TUI. `EPIPE`, błąd lub timeout oznacza rozłączenie i reconnect, nie zakończenie procesu Herdr. Błąd ustawienia opcji zamyka transport i jest raportowany bez przerywania TUI.
- Heartbeat: ponowne pobranie projekcji w kontekście stanu klienta i pełny snapshot co 2 s bez innych zmian. Task transportu nie odświeża timestampu starej próbki samym ponownym wysłaniem. Zawieszona pętla stanu klienta nie może udawać aktualności dzięki żyjącemu wątkowi I/O. Heartbeat nie czyni cache remote aktualnym; `stale` nadal pochodzi z Herdr.
- Backoff po braku listenera/błędzie: 1, 2, 4, maksymalnie 5 s. Reset do 1 s dopiero po co najmniej 4 s utrzymanego połączenia i udanych zapisach w dwóch kolejnych interwałach heartbeat, nie po pierwszym wysłaniu. Trwałe odrzucenie nie powoduje ciasnej pętli ani nieograniczonych logów; diagnostyka jest ograniczona częstotliwościowo. Oczekiwanie, connect i backoff nigdy nie działają w pętli renderowania. Start/restart companiona może czekać do kolejnej próby (do 5 s); cel 1 s dotyczy już zdrowego połączenia.
- Po connect transport odrzuca poprzedni bufor oraz niedokończoną wiadomość i żąda pełnej nowej próbki z pętli stanu klienta. Pierwszy snapshot musi zostać pobrany po zestawieniu połączenia, najpóźniej przy następnym heartbeat (2 s). Niczego nie replayujemy. Jeśli pętla klienta nie odpowiada, brak świeżej próbki prowadzi do timeoutu połączenia.

### Odbiór i walidacja

- Maksymalna długość linii: 1 MiB, bez LF; limit sprawdzany przed nieograniczonym buforowaniem. Brak LF nie znosi limitu.
- Maksymalnie 64 jednoczesne połączenia, z ograniczonym buforem wejścia per połączenie; nadmiar jest odrzucany jawnie w diagnostyce.
- Wymagane typy i pola, poprawny identyfikator klienta, unikalne endpointy/panele w ich zakresach, dokładnie enum statusów v1. Etykiety/ID do 1024 bajtów UTF-8 każda; żadnych znaków sterujących w etykietach UI.
- Nieznane dodatkowe pola są ignorowane. Nieznana wersja główna, nieobsługiwany status, błędna struktura, duplikaty, przekroczenie limitów, timestamp z przyszłości lub malejący względem ostatniej próbki tego połączenia powodują odrzucenie całej wiadomości i zamknięcie połączenia. Nie konwertować nieznanego statusu na `unknown`. `sampled_at_ns` jest liczbą całkowitą `u64`, nie zmiennoprzecinkową.
- Błąd jest widoczny w diagnostyce menu. Nie zastępować dobrego stanu częściowo odczytaną wiadomością i nie logować payloadu.
- Pierwszy poprawny, aktualny snapshot ustala `client_id` połączenia; kolejne nie mogą go zmienić. Nowe połączenie tego samego klienta zastępuje poprzednie dopiero po poprawnej nowej próbce nie starszej od ostatniej zaakceptowanej dla tego `client_id`. EOF starego połączenia nie może rozłączyć jego następcy.
- Świeżość jest liczona od `sampled_at_ns`, nie od chwili spóźnionego odczytu z bufora socketu. Nowa poprawna i aktualna próbka odświeża stan; przeterminowana nie przedłuża aktualności ani retencji. W jednym połączeniu czas próbki nie może cofać się.

## 6. Aktualność i reconnect

Rozdzielamy status agenta, aktualność endpointu Herdr i połączenie z lokalnym klientem.

- Wiek ostatniej próbki ponad 6 s lub EOF/błąd: zamykamy połączenie i cała sekcja lokalnego klienta jest nieaktualna. Od chwili wykrycia rozpoczyna się 30 s retencji; kolejne błędy nie przedłużają jej. Połączenie bez pierwszej poprawnej, aktualnej próbki w ciągu 6 s też jest zamykane i nie tworzy aktualnej sekcji.
- Poprawny reconnect i snapshot w tym czasie przywraca sekcję; po 30 s bez odzyskania źródła usuwamy sekcję i cache. Restart procesu z nowym `client_id` jest nową sekcją, nie arbitralnym scaleniem.
- Remote stale w żywym kliencie: jego cache pozostaje oznaczony jako nieaktualny tak długo, jak utrzymuje go Herdr. Nie uruchamiamy osobnego 30 s usuwania takiego endpointu.
- Bieżące liczniki sekcji obejmują tylko agentów aktualnych endpointów przy aktualnym połączeniu klienta. Obok podajemy liczbę agentów z nieaktualnych danych. Gdy cała sekcja jest nieaktualna, bieżące liczniki mają `—`, nie pozorne zera.
- Znane cache `blocked`/`done` można nadal pokazywać w przygaszonych wierszach z tekstem „dane nieaktualne”, bez zmiany statusów.
- Terminy 6 s i 30 s obsługuje kolejka/task odbiorcy, nie wątek UI. Używa lokalnego zegara monotonicznego uwzględniającego uśpienie. Na wake companion oznacza cache jako nieaktualny i zamyka stare połączenia; świeży snapshot po reconnect przywraca stan. Nie uznaje danych z bufora sprzed sleep za nowe.
- Aktualność oznacza świeżą projekcję raportowaną przez Herdr, nie niezależne potwierdzenie faktycznej aktywności odległego procesu. Detekcja sieci remote pozostaje odpowiedzialnością Herdr.

## 7. Socket, uprawnienia i cykl życia

- Jedna stała krótka ścieżka listenera: `confstr(_CS_DARWIN_USER_TEMP_DIR)` + podkatalog `hso-v1` + plik `overlay.sock`. Obie niesandboxowane strony korzystają dokładnie z tej samej reguły; nie używają `NSTemporaryDirectory()` ani dowolnie nadpisanego `TMPDIR` procesu.
- Ścieżka sprawdzana w bajtach względem pojemności `sockaddr_un.sun_path`, z miejscem na terminator. Zbyt długa ścieżka to jawny błąd, bez obcinania i niebezpiecznego fallbacku w publicznym katalogu.
- Katalog `0700`, socket `0600`, właściciel = bieżący UID. Obie strony sprawdzają UID partnera przez systemowy mechanizm peer credentials. To granica użytkownika, nie sandbox przed innym złośliwym procesem tego samego użytkownika.
- Listener ma wyłączną blokadę procesu w `hso-v1/overlay.lock` na cały czas życia. Katalog sprawdzany bez podążania za dowiązaniami; plik blokady otwierany z `O_NOFOLLOW|O_CLOEXEC`, weryfikowany przez `fstat` (zwykły plik, bieżący UID, `0600`), blokowany przez `flock(LOCK_EX|LOCK_NB)`. Druga instancja aplikacji nie przejmuje socketu i kończy się bez naruszania pierwszej.
- Stary wpis socketu można usunąć wyłącznie po uzyskaniu blokady, weryfikacji bez dowiązań, właściciela, typu i położenia wpisu. Niezgodność powoduje błąd, nie unlink obcego pliku. Uchwyt blokady i ścieżka nie są zwalniane w trakcie działania listenera.
- Przy quit aplikacja kończy akceptowanie, zamyka połączenia i usuwa wyłącznie własny socket; exporter przechodzi w backoff. Wyłączenie eksportu lub zamknięcie klienta kończy tylko jego transport.
- Brak logowania payloadów, nagrywania ekranu, Accessibility/Automation do sterowania terminalami, portów TCP i poleceń wstecznych.

## 8. Zachowanie panelu

- Początkowo widoczny w prawym górnym rogu głównego monitora, z marginesem do obszaru roboczego. Można przeciągnąć za tło. Nie kradnie fokusu przy starcie, aktualizacji, reconnect ani zmianie liczników.
- Zapamiętuje widoczność i pozycję względem monitora. Po odłączeniu monitora przenosi się do obszaru roboczego głównego; po zmianie rozdzielczości pozycja jest przycinana do widocznego obszaru.
- Maksymalna wysokość 40% obszaru roboczego wybranego monitora; treść przewijana bez dodatkowego rozwijania. Nie ukrywa automatycznie zakończonych zadań.
- Sekcje w stabilnej kolejności pierwszego pojawienia; wiersze `blocked`, potem `done`, wewnątrz grupy deterministycznie po etykiecie maszyny, workspace i agenta/ID.
- Panel nie pokazuje pełnej listy working/idle/unknown; te stany są w licznikach. Nazwy blocked/done są stale dostępne w przewijanej treści.
- Brak podłączonych klientów: informacja „Brak klientów Herdr z włączonym eksportem”, a nie „wszyscy agenci skończyli”. Klient bez agentów: osobna aktualna sekcja z zerami.
- Status i aktualność rozpoznawalne przez tekst, nie wyłącznie kolor. Standardowe dostępne kontrolki, etykiety VoiceOver, czytelny kontrast. Niezmieniony heartbeat nie przebudowuje widoku i nie generuje ogłoszeń VoiceOver. Weryfikacja dostępności jest częścią implementacji.
- Początkowa konfiguracja okna: `.borderless` + `.nonactivatingPanel`, poziom `.floating`, `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.canJoinAllApplications`, `hidesOnDeactivate = false`. Zmiany dopiero na podstawie próby, bez prywatnych API Spaces i bez podnoszenia do poziomu systemowych alertów.

## 9. Baza i dostarczenie

- Baza pierwszego izolowanego patcha: sprawdzony upstream commit `5608de0608918aba2f9d501e7793b984a0ca9cfa`. Nie zakładamy, że jest to wydanie 0.9.5; nie obiecujemy backportu.
- Bramka przed etapem 4: wyłącznie odczytem potwierdzić zgodność protokołu izolowanego klienta z rzeczywistymi lokalnymi i zdalnymi serwerami użytkownika; wersji remote nie zakładamy. Przy niezgodności lub braku dowodu zatrzymać próbę na istniejących sesjach. Można po osobnym uzgodnieniu użyć nowej odizolowanej sesji/serwera testowego lub po weryfikacji zmienić bazę patcha na zgodną. Nigdy nie aktualizować, nie restartować, nie zatrzymywać ani nie wykonywać handoffu serwerów użytkownika, nie podążać automatycznie za sugestią updatera. Nowy serwer lub połączenie remote wymaga odrębnej zgody; sam test zgodności nie może go uruchamiać.
- Kod companiona i kontrakt/fixtury w tym repo. Patch klienta w osobnym checkoutcie/buildu przypiętym do bazy. Opt-in zapisujemy wyłącznie w osobnym testowym pliku wskazanym przez `HERDR_CONFIG_PATH` ustawione dla procesu izolowanego klienta; nie dopisujemy nowych kluczy do zwykłego configu użytkownika i nie zmieniamy globalnego środowiska. Sposób zachowania patcha i odtwarzalnego builda opisać przy implementacji; nie zmieniać gałęzi ani instalacji użytkownika.
- Target companiona: macOS 13+ (publiczne `canJoinAllApplications` od 13). Dotąd praktycznie sprawdzono tylko lokalny macOS 27.0.1, arm64. Nie deklarować testów macOS 13 ani Intel bez ich wykonania.
- Pierwsze dostarczenie: lokalna aplikacja `.app` i jawna ścieżka izolowanego Herdr do ręcznego uruchomienia. Bez instalatora, autostartu, publikacji, notarization i zmiany globalnych ustawień. Podpis niezbędny do lokalnego uruchomienia nie oznacza dystrybucyjnego podpisania/notaryzacji.
- Ewentualna dystrybucja i upstream to osobna decyzja po testach; brak akceptacji upstream nie może być ukrytym warunkiem działającego lokalnego MVP.

## 10. Etapy wdrożenia i bramki

To plan etapów, nie instrukcja rozpoczęcia implementacji.

1. **Kontrakt i małe testy:** golden fixtures NDJSON, walidacja, atomowe zastępowanie, staleness/30 s/clock, framing, wersje, limity. Zdefiniować standardowy sposób uruchamiania testów bez Herdr i GUI. Gotowe, gdy oba języki zgadzają się co do fixture i błędów.
2. **Exporter w izolowanym Herdr:** hook po projekcji, opt-in, transport/background, backoff i latest-wins. Testy natywne repo Herdr celowane na zmienione moduły plus format/lint; bez dodatkowego SSH. Gotowe, gdy absent/slow/crashed companion nie wpływa na wejście/render i pamięć nie rośnie bez limitu.
3. **Companion z prawdziwymi danymi:** listener, model źródeł, menu, panel, pozycja/widoczność, allowlista. Testy modelu i lokalnej komunikacji obejmujące startup w obu kolejnościach, restart, błędy i wielu klientów. Gotowe, gdy liczniki i widoczne wiersze spełniają kontrakt.
4. **Integracja i odporność:** local/remote z istniejącymi klientami, dwa klienty tej samej sesji, filtry sidebaru, offline/reconnect, sleep/wake i przeciążenia. Próby GUI/SSH wymagające nowych efektów uzgodnić przed wykonaniem; nie zmieniać instalacji. Gotowe po zaliczeniu odpowiedniej macierzy z dowodami, nie samym braku błędów.
5. **Codzienne użycie:** fullscreen Safari/terminal, drugi Space, hide/show/quit, monitor/pozycja i dostępność. Zebrać konkretne obserwacje opóźnień i zachowania. Nie dodawać funkcji poza zakresem jako warunku ukończenia.

Dokładne komendy testów zostaną dobrane z faktycznych manifestów projektu podczas implementacji; nie wpisujemy fikcyjnych istniejących skryptów. Code review ryzykownego diffu Herdr/IPC wykonać w świeżym kontekście przed uznaniem implementacji za gotową, przez MCP Claude Code zgodnie z preferencją użytkownika.

## 11. Kryteria odbioru

| ID | Wymagany wynik |
| --- | --- |
| A1 | Panel widoczny nad sprawdzonym fullscreen Safari i terminala w innym Space; aktualizacja nie odbiera fokusu. |
| A2 | Local i remote ze wszystkich podłączonych klientów w odpowiednich osobnych sekcjach; filtr sidebaru nie ukrywa agenta w overlayu. |
| A3 | Wszystkie 5 statusów oraz przejścia working/blocked/done/idle/unknown wierne projekcji; odczyt overlayu nie zmienia seen/ack. |
| A4 | Ta sama sesja w dwóch klientach zachowuje różnice done/idle; brak globalnej deduplikacji i sumy udającej unikalnych agentów. |
| A5 | W normalnych warunkach aktualizacja widoczna do 1 s od przyjęcia zmiany przez lokalnego klienta Herdr. Nie jest to obietnica opóźnienia detekcji agenta/SSH. |
| A6 | Pełne snapshoty obsługują usunięcia i reconnect bez replay. Zmiana client_id, EOF starego połączenia, duplikaty, nieznany status, cofnięty/przyszły czas, błędna lub częściowa wiadomość nie nadpisują dobrego stanu. |
| A7 | EOF, brak pierwszej próbki i timeout świeżości 6 s dają odpowiedni błąd lub nieaktualną sekcję, usuwaną po 30 s. Zawieszona pętla klienta przy żywym I/O nie odświeża stanu. Stale remote nie wchodzi do bieżących liczników. |
| A8 | Sleep/wake, utrata sieci remote, restart klienta/aplikacji nie przywracają starych danych jako świeżych. |
| A9 | Nieobecny/wolny companion, jego crash/zamknięcie w trakcie zapisu i lawina zmian nie blokują ani nie kończą TUI; kolejki/pamięć ograniczone. Sprawdzić brak regresji wejścia i renderowania względem builda bez eksportu, z podaniem warunków i pomiarów. |
| A10 | Błędny UID, dowiązanie/obcy wpis socketu lub blokady, równoczesny start, zła wersja, przerośnięta wiadomość i limit 64 połączeń są obsłużone bez wycieku lub usuwania obcych danych. |
| A11 | Hide/show i pozycja przetrwają restart; odłączenie monitora nie gubi panelu; quit nie zatrzymuje agentów. |
| A12 | W transporcie, logach i stanie trwałym brak ekranów, komend, cwd i innych pól poza allowlistą; nigdzie nie powstaje dodatkowe SSH ani port TCP. |
| A13 | Pusty klient, brak klientów, bardzo wiele blocked/done i nieaktualne źródła są czytelnie odróżnione; nazwy i statusy dostępne bez polegania tylko na kolorze. |
| A14 | Bez jawnego opt-in klient nie podejmuje prób połączenia. Konfiguracja remote ani reload serwera go nie włączają. W MVP wyłączenie zaczyna obowiązywać przy ponownym starcie samego klienta, bez restartu agentów. Testowy config i środowisko procesu pozostają odizolowane od zwykłej instalacji. |
| A15 | Przed integracją na istniejących sesjach potwierdzono read-only zgodność protokołu z rzeczywistymi serwerami local/remote. Niezgodność lub brak dowodu zatrzymuje test, bez aktualizacji/restartu/handoffu istniejącego serwera. Osobne środowisko testowe wymaga uzgodnienia. |

## 12. Dotychczasowe dowody i pozostałe ryzyko

- Herdr 0.9.5: sprawdzono pomoc/schemat i read-only snapshot lokalnej sesji. Nie eksportują agregatu klientów. Detale źródła eksportera ustalono z podanego commita upstream, nie z całego kodu wydania 0.9.5.
- Jednorazowa próba AppKit poza repo skompilowana poprawnie. Użytkownik po instrukcji fullscreen odpowiedział „Widać nie przeszkadza”. To ręczne potwierdzenie tylko tej próby; bez screenshotów, integracji danych i pełnej macierzy GUI.
- Claude Code przez MCP przejrzał wcześniejszą architekturę i następnie tę specyfikację. Raporty: [architektura](../reviews/claude-architecture-review.md), [końcowe potwierdzenie specyfikacji](../reviews/claude-spec-review.md). Końcowy werdykt: ACCEPT dla dokumentu; bez testów implementacji.
- Nie wykonano implementacji, testów protokołu, pomiaru opóźnień/backpressure, testów sleep/wake, wielu monitorów, starszego macOS, Intel ani pakowania produktu.
- Ograniczenia statusów/detekcji i aktualności endpointów Herdr pozostają ograniczeniami źródła. Overlay nie jest niezależnym systemem monitoringu procesów remote.
