# Research techniczny

> **Dokument historyczny.** Użytkownik zastąpił wariant patcha klienta pluginem i helperem odczytującym API oraz własnym DONE z `completion_seq`. Aktualny zakres: [plan implementacji](implementation-plan.md); instrukcje i stan kodu: [README](../README.md). Dawne zgody i deklaracje braku implementacji poniżej opisują wcześniejszy etap, nie obecny stan.

## Zakres i jakość dowodów

Pierwszy etap obejmował read-only research dokumentacji publicznej, kodu upstream Herdr, lokalnego repo `../herdr-agent-bridge` oraz pomocy zainstalowanych programów. W kolejnym etapie uruchomiono jednorazowy panel z fikcyjnymi danymi; wynik opisano poniżej. Nie automatyzowano okien, nie zmieniano fokusu aplikacji i nie otwierano nowych połączeń SSH w celu weryfikacji overlayu.

Zaobserwowane lokalnie wersje:

- Herdr: `0.9.5` (`herdr --version`).
- Ghostty: `1.3.1`, kanał stable (wersja z lokalnego executable).
- Sprawdzony upstream Herdr: commit ze skrótem `5608de0` na gałęzi master. Nie utożsamiać go z kodem zainstalowanego wydania.
- Dokumentacja internetowa Herdr odsyłała do `docs/versions/0.9.5/website/src/content/docs/`. Dla implementacji trzeba ponownie sprawdzić zgodność API z faktycznie używaną wersją.

## Potwierdzone możliwości Herdr

### Statusy i zdarzenia

- `agent.list` zwraca agentów z workspace'ów, zakładek i paneli jednego serwera/sesji.
- Model statusów obejmuje `idle`, `working`, `blocked`, `done`, `unknown`.
- Dokumentacja opisuje `done` jako idle, którego użytkownik jeszcze nie zobaczył. Overlay ma konsumować status Herdr, nie odtwarzać tej reguły samodzielnie.
- `AgentInfo` zawiera m.in. identyfikatory terminala Herdr, workspace, tab i pane, nazwę/agenta, status oraz informacje prezentacyjne.
- `events.subscribe` obsługuje m.in. `pane.agent_status_changed` i zdarzenia cyklu życia paneli.
- `session.snapshot` umożliwia pobranie bieżącego obrazu sesji.
- Zdarzenia nie są trwałym dziennikiem. `events_lost` wymaga ponownej subskrypcji i uzgodnienia stanu przez autorytatywne odczyty.
- Snapshot i zdarzenia nie mają wspólnej granicy sekwencji: nie należy bezwarunkowo nakładać buforowanych zdarzeń na snapshot. Dokumentacja zaleca subskrypcję przed odczytem i traktowanie zdarzeń jako sygnałów unieważnienia cache.

### Local i remote

Herdr już prezentuje zbiorczą listę agentów z połączonych maszyn. Agregacja należy jednak do klienta, nie do pojedynczego endpointu serwera.

- Jedno lokalne `agent.list` nie jest potwierdzonym globalnym eksportem listy widocznej w kliencie.
- `herdr machine list --json` listuje zapisane profile maszyn; nie dowodzi, że konkretny klient jest z nimi aktualnie połączony.
- `herdr --machine <label-or-id> agent list` kieruje zapytanie do wskazanej zapisanej maszyny/sesji. Jest alternatywną drogą odczytu, ale nie gotowym eksportem istniejącego cache klienta.
- Jeden profil maszyny wskazuje jedną sesję remote, nie wszystkie sesje hosta.
- Identyfikatory paneli i nazwy agentów są lokalne dla serwera. Dwie maszyny mogą mieć to samo `w1:p1`.
- Herdr pokazuje rozłączone dane jako przygaszony cache. Overlay również musi rozróżniać aktualność źródła od statusu agenta.
- CLI ma `herdr session list --json`; sesje nazwane mają osobne sockety. To nie jest potwierdzony rejestr otwartych okien/klientów.

**Potwierdzone ograniczenie publicznego API 0.9.5:** schemat zainstalowanego programu i odczyt `herdr api snapshot` nie udostępniają zbiorczej projekcji klientów local + remote. API zwraca pojedynczą sesję. Osobne odpytywanie zapisanych maszyn jest możliwym innym modelem produktu, a nie wiernym eksportem istniejących klientów.

### Pluginy

- Plugin to manifest `herdr-plugin.toml` i polecenia wykonywane jako zwykłe programy użytkownika.
- Może być ograniczony do `platforms = ["macos"]`.
- Ma dostęp do CLI/socket API i kontekstu, m.in. `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, katalogów konfiguracji i stanu.
- Plugin v1 nie udostępnia natywnego nieterminalowego UI.
- Pluginowe `placement = "overlay"` oznacza panel wewnątrz Herdr, nie okno nad innymi aplikacjami macOS.
- Pluginy mają enable/disable, ale nie należy zakładać, że wyłączenie automatycznie kończy dowolną uruchomioną aplikację pomocniczą.
- Hooki startup są jednorazową inicjalizacją, nie nadzorowanymi daemonami. Dokumentacja wymaga zatrzymania odłączonych procesów pluginu przed końcem jego procesu/panelu. Nie projektować trwałego helpera przez niekontrolowane odłączenie go z hooka.

## Natywny panel macOS

Publiczne API AppKit daje podstawę do rozwiązania:

- `NSPanel` z `nonactivatingPanel`: okno nie aktywuje swojej aplikacji przy samym wyświetleniu.
- `canJoinAllSpaces`: mechanizm uczestnictwa w Spaces.
- `fullScreenAuxiliary`: okno może być w tym samym Space co okno pełnoekranowe.
- `canJoinAllApplications` (od macOS 13): Apple opisuje tę opcję jako przeznaczoną dla pływających okien i overlayów, pozwalającą kwalifikującym się oknom dołączać do pełnoekranowych Spaces innych aplikacji i nie uczestniczyć w układzie Stage Manager.

To potwierdza kierunek techniczny, **nie gwarantuje**, że wybrana kombinacja poziomu okna, stylu i polityki aktywacji zadziała we wszystkich konfiguracjach. Nie ustalono ostatecznych flag ani minimalnego systemu. Wymagane próby: Safari fullscreen, przełączanie Spaces, wiele monitorów, zachowanie fokusu i włączanie/wyłączanie.

Rekomendowany kandydat: mały helper Swift/AppKit, ewentualnie SwiftUI do zawartości panelu. Nie ma obecnie uzasadnienia dla Electron tylko do tego widoku. To rekomendacja, nie wybrany i przetestowany stos implementacyjny.

## Rozważane warianty

### A. Companion używający wyłącznie obecnego API

Osobna aplikacja macOS odkrywa sesje/maszyny, odczytuje agentów i wyświetla ich statusy.

Zaleta: potencjalnie bez zmian upstream. Koszt: własne zebranie źródeł, deduplikacja i obsługa połączeń; dane mogą nie odpowiadać dokładnie połączeniom istniejącego klienta. Nie potwierdzono, że da się uniknąć dodatkowej obsługi zdalnych endpointów.

### B. Companion z cienkim eksportem danych klienta Herdr

Lokalni klienci udostępniają istniejące listy local + remote jednej aplikacji wyświetlającej panel.

Zaleta: wykorzystanie istniejącej agregacji i połączeń SSH, wierniejszy obraz tego, co pokazuje Herdr. Koszt: prawdopodobne rozszerzenie klienta/upstream API oraz zaprojektowanie lokalnej komunikacji i cyklu życia.

Użytkownik zatwierdził ten kierunek oraz read-only Unix socket z jednym listenerem w companionie i klientami-nadawcami opt-in. Pełne snapshoty, osobne sekcje/liczniki klientów i brak własnego SSH. Szczegóły kontraktu i plan implementacji wymagają jeszcze domknięcia.

### C. Panel całkowicie wbudowany w Herdr

Natywne UI w istniejącej terminalowej aplikacji Rust. Możliwe koncepcyjnie, ale większe sprzężenie z cyklem życia i platformą; nie jest pierwszym wyborem dla małego MVP.

## Ustalenia dotyczące nawigacji — odłożone poza MVP

Zachowane dla przyszłego powrotu do pomysłu, nie jako wymagania pierwszej wersji:

- Herdr działa wewnątrz zewnętrznego terminala, nie jest samodzielnym oknem GUI.
- `agent.focus` wybiera agenta w kontekście Herdr, nie daje gwarancji podniesienia okna systemowego.
- Klienci mogą niezależnie oglądać różne zakładki jednego serwera. Zdarzenie `pane.focused` nie zawiera tożsamości klienta.
- Nie znaleziono w sprawdzonym publicznym API operacji podniesienia konkretnego okna zewnętrznego terminala ani jego systemowego ID. To ograniczone ustalenie researchu, nie dowód braku każdego możliwego mechanizmu.
- `terminal_id` Herdr nie jest identyfikatorem okna macOS.
- Ghostty od 1.3.0 ma AppleScript; lokalny słownik 1.3.1 potwierdza stabilne ID okien, zakładek i terminali oraz `focus` opisane jako podnoszące okno terminala.
- Lokalny słownik odczytano z `/Applications/Ghostty.app/Contents/Resources/Ghostty.sdef`. Nie potwierdzono w nim właściwości `tty`/`pid`, mimo że występowały w wynikach wyszukiwania; nie opierać na nich projektu dla tej wersji.
- Sterowanie Ghostty może wymagać uprawnienia macOS Automation. Nie wywoływano AppleScript ani promptów uprawnień.
- W procesie wewnątrz panelu `TERM_PROGRAM=herdr`; nie identyfikuje to zewnętrznego terminala. W tej sesji `GHOSTTY_SURFACE_ID` i `GHOSTTY_WINDOW_ID` były puste.
- iTerm2 dokumentuje `iterm2:reveal?sessionid=...` jako drogę do konkretnej sesji; nie testowano jej.

Odrzucenie nawigacji z MVP usuwa problem mapowania okien i sterowania terminalami, ale nie usuwa problemu pozyskania zbiorczych danych local + remote.

## Punkty wejścia w kodzie upstream

Odniesienia do sprawdzonego master `5608de0`; linie mogą zmienić się w późniejszych wersjach:

| Plik | Obszar |
| --- | --- |
| `src/app/agents.rs:23–36` | Zbieranie agentów jednego serwera |
| `src/app/api/agents.rs:35–43` | Odpowiedź `agent.list` |
| `src/api/schema/agents.rs:209–244` | `AgentInfo` |
| `src/api/schema/common.rs:247–253` | Statusy |
| `src/api/schema/events.rs:35–82,399–405` | Typy zdarzeń/status changes |
| `src/client/shell/endpoints.rs:220–248` | Projekcje endpointów i agregacja należąca do klienta |
| `src/app/agents.rs:75–90` | Focus agenta; poza MVP |
| `src/server/headless/tests/mod.rs:2130–2204` | Test niezależnej nawigacji klientów; poza MVP |

Lokalny `../herdr-agent-bridge` jest adapterem MCP do współpracy agentów, nie globalnym źródłem statusów klienta. Badane punkty: `src/herdr.ts`, `src/observe.ts`, `src/binding.ts`, `docs/architecture.md`. Nie ma powodu uzależniać overlayu od sesji i raportów tego bridge'a.

## Źródła

- [Herdr — Plugins](https://herdr.dev/docs/plugins/)
- [Herdr — Socket API](https://herdr.dev/docs/socket-api/)
- [Herdr — Connecting machines](https://herdr.dev/docs/connecting-machines/)
- [Herdr — Integrations](https://herdr.dev/docs/integrations/)
- [Herdr upstream](https://github.com/herdrdev/herdr)
- [Apple — canJoinAllApplications](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications)
- [Apple — fullScreenAuxiliary](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary)
- [Apple — nonactivatingPanel](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)
- [Ghostty — AppleScript](https://ghostty.org/docs/features/applescript)
- [iTerm2 — Reveal URLs](https://iterm2.com/documentation-command-selection.html)

Dla stron Apple renderowanych przez JavaScript odczytano oficjalne dokumenty JSON: [canJoinAllApplications](https://developer.apple.com/tutorials/data/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications.json), [fullScreenAuxiliary](https://developer.apple.com/tutorials/data/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary.json) i [nonactivatingPanel](https://developer.apple.com/tutorials/data/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel.json). Wątek Apple Developer Forums o overlayach był zablokowany weryfikacją; nie traktowano jego treści jako potwierdzonej recepty.

## Wynik jednorazowej próby panelu macOS

Po zgodzie użytkownika skompilowano i uruchomiono tymczasowy program Swift/AppKit poza repozytorium produktu. Dane były fikcyjne; brak połączeń z Herdr i SSH. Kompilacja zakończyła się kodem 0; program zawierał asercje konfiguracji panelu.

Użyta konfiguracja: `NSPanel` z `.borderless` i `.nonactivatingPanel`, poziom `.floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]`, `hidesOnDeactivate = false`, aplikacja `.accessory`. Panel miał licznik aktualizowany co 3 sekundy, menu ukrywania/pokazywania i automatyczne zakończenie po 15 minutach.

Po instrukcji przejścia do Safari fullscreen i sprawdzenia pisania użytkownik odpowiedział: „Widać nie przeszkadza”. Potwierdza to ręcznie widoczność i brak przeszkadzania w sprawdzonej konfiguracji. Nie wykonano screenshotów ani niezależnej weryfikacji obrazu; nie potwierdzono osobno aktualizacji licznika, przełącznika ukrywania, wielu monitorów, Stage Manager, sleep/wake ani innych wersji macOS. Wynik nie potwierdza integracji z prawdziwymi statusami.

## Uzupełnienie: źródło danych i semantyka wielu klientów

Dodatkowa weryfikacja objęła schemat faktycznie zainstalowanego Herdr 0.9.5, read-only snapshot działającej lokalnej sesji oraz dalszą analizę upstream `5608de0`. Nie otwierano dodatkowych połączeń SSH.

### Co potwierdzono na działającym 0.9.5

`herdr api snapshot` zwrócił `agents`, `focused_pane_id`, `focused_tab_id`, `focused_workspace_id`, `layouts`, `panes`, `protocol`, `tabs`, `version`, `workspaces`. Nie zwrócił zbiorczej listy klientów/endpointów ani tożsamości serwera/sesji jako UUID. Same pola `terminal_id` lub `pane_id` nie dowodzą globalnej tożsamości.

### Co potwierdzono w upstream, nie na lokalnym UI 0.9.5

- `src/client/shell/endpoint_agents.rs:125–176`: `agent_rows(...)` buduje wiersze sidebaru z tożsamością endpointu, etykietą maszyny, statusem aktualności i agentem. To konkretny kandydat na punkt eksportu gotowej projekcji.
- `src/client/shell/aggregate_navigation.rs:56–157`: agregacja łączy wiersze endpointów; nie deduplikuje różnych profili wskazujących ten sam serwer.
- `src/client/shell/endpoint_agent_state.rs:72–178`: status `idle`/`done` jest projektowany przez lokalny stan ukończenia i potwierdzenia obejrzenia. Dwaj klienci mogą zgodnie z logiką Herdr pokazywać tego samego agenta odpowiednio jako `idle` i `done`.
- `src/client/endpoint.rs:50–108`: endpoint to Local lub SSH z identyfikatorem zapisanego profilu. Dwa profile/aliasy nie są dowodem dwóch różnych serwerów, ale ich automatyczne scalenie też nie jest uzasadnione.
- `src/protocol/wire.rs:916–923`: `boot_id` zmienia się przy restarcie endpointu; `revision` jest monotoniczne w obrębie tego uruchomienia. Nie potwierdzono kontraktu kanonicznej tożsamości serwera pozwalającego scalać aliasy.

**Rozstrzygnięcie użytkownika po researchu:** osobna sekcja i liczniki dla każdego klienta Herdr, bez globalnego licznika unikalnych agentów i bez deduplikacji między klientami. Każda sekcja zachowuje własne statusy klienta, także gdy dwie projekcje tej samej sesji różnią się `done`/`idle`. To zastępuje wcześniejsze wymaganie jednokrotnego liczenia tej samej sesji we wszystkich oknach.

**Zatwierdzony kierunek planu:** niewielkie rozszerzenie klienta Herdr eksportuje lokalnie istniejące statusy do osobnego natywnego companion. Companion nie otwiera własnych połączeń SSH. Użytkownik dopuścił zmiany Herdr w planie, nie zmianę swojej instalacji ani implementację protokołu bez dalszego uzgodnienia.

## Następny krok

Końcowa specyfikacja i etapy zostały zapisane w [specs/status-overlay-design.md](specs/status-overlay-design.md), a Claude Code przez MCP potwierdził dokument jako ACCEPT po poprawkach. [Raport końcowy](reviews/claude-spec-review.md). Następnym etapem może być implementacja po osobnej zgodzie użytkownika; przed integracją na istniejących sesjach obowiązuje read-only bramka zgodności protokołu, bez restartowania lub aktualizacji serwerów użytkownika. Integracji i testów produktu jeszcze nie wykonano.
