# Testy live — niewykonane

Każdy z tych testów produktu wymaga osobnej zgody użytkownika (GUI, link pluginu, odczyt prawdziwego Herdr lub SSH). Dla produktu wykonano build i headless self-check; wcześniejsze próby samego API local/remote nie są odbiorem helpera.

| ID | Test | Oczekiwany wynik |
| --- | --- | --- |
| L1 | `herdr plugin link`, akcja „Status overlay: start” | Panel pluginu otwiera się w tle bez zmiany fokusu; helper działa w jego pierwszym planie. |
| L2 | GUI z procesu w PTY serwera Herdr | Panel i menu `HSO` widoczne; brak ikony Dock; brak aktywacji aplikacji. |
| L3 | Safari fullscreen i terminal w innym Space (A1) | Panel widoczny nad oboma; aktualizacja nie zabiera fokusu. |
| L4 | Zamknięcie panelu pluginu / Quit / `kill -TERM` | Helper i procesy `herdr agent list` / ssh kończą się; agenci działają. |
| L5 | Druga akcja przy działającym helperze | „już działa”, pierwszy helper nietknięty. |
| L6 | Local: agent working → idle bez otwierania jego panelu | Wiersz `DONE` po zmianie `completion_seq`; OK go usuwa; stan Herdr bez zmian. |
| L7 | Restart helpera przy zastanych idle | Brak fałszywych `DONE` (baseline). |
| L8 | Remote z `machines.txt` (alias zapisany) | Sekcja aliasu, odczyt co ok. 5 s + czas odczytu (pomiar koordynatora: 3,75 s). |
| L9 | Remote niedostępny / wygasłe połączenie SSH | Brak promptu hasła; sekcja nieaktualna, backoff 5/10/30 s, brak lawiny procesów. |
| L10 | Sleep/wake | Po wybudzeniu dane oznaczone jako nieaktualne; pierwszy odczyt nie tworzy `DONE`. |
| L11 | Odłączenie monitora / zmiana rozdzielczości | Panel wraca do widocznego obszaru; pozycja zapamiętana po restarcie (A11). |
| L12 | Wiele wierszy blocked/done | Wysokość ≤ 40% ekranu, przewijanie, stabilna kolejność. |
| L13 | VoiceOver | Etykiety sekcji, liczników i przycisków OK czytelne; heartbeat bez ogłoszeń. |
| L14 | Pomiar kosztu: CPU, liczba procesów ssh przez 10 min z jednym aliasem | Brak narastania procesów; wynik zapisany. |
| L15 | macOS 13 i Intel | Nie testowano; deployment target to macOS 13. |

## Przygotowanie i granice zgody

- Wymagane: lokalny build release, działający Herdr w sesji GUI macOS, zanotowana aktywna aplikacja i stan zarejestrowanych pluginów. Dla L8/L9/L14 dodatkowo już zapisany alias remote i jawna zgoda na odczyty SSH. Nie dodawać maszyn, nie restartować/aktualizować/handoffować serwerów ani nie zatrzymywać agentów.
- L1: po zgodzie na rejestrację wykonać `herdr plugin link "$PWD"` w repo, a potem `herdr plugin action invoke open --plugin local.status-overlay`. Dozwolone skutki: rejestr pluginu, jedna nowa zakładka helpera, natywny panel i menu oraz lokalne odczyty API. Zrobić zrzuty przed/po i sprawdzić, że aktywne okno nie zmieniło się.
- L2/L3: przejść ręcznie do Safari fullscreen, następnie fullscreen terminala i innego Space; wpisać tekst w bezpiecznym pustym polu, poczekać na aktualizację. Obejrzeć screenshoty panelu i aktywnej aplikacji; bez ich obejrzenia nie deklarować zaliczenia GUI.
- L4/L5/L7: zanotować PID helpera i jego dzieci, uruchomić drugą akcję; sprawdzić jedną instancję, a następnie osobno Quit, zamknięcie zakładki i `kill -TERM <PID-helpera>`. Po każdym sprawdzić brak helpera/jego odczytów oraz dalszą pracę agentów. Po ponownym starcie zastane idle nie tworzą DONE.
- L6: zlecić wskazanemu testowemu agentowi odpowiedź bez zmian plików, nie otwierać jego panelu; poczekać na DONE, potwierdzić przyciskiem OK, sprawdzić brak input/focus/ack w Herdr. Powtórzyć po restarcie helpera.
- L8/L9/L14: zachować poprzedni `machines.txt` (albo zanotować brak), dopisać wyłącznie uzgodniony alias, ponownie uruchomić helper. Obserwować sekcję i procesy 10 min. Niedostępność symulować wyłącznie w osobnym uzgodnionym środowisku, nie przerywać aktywnego SSH/ControlMaster użytkownika. Brak takiego środowiska blokuje L9 zamiast wymuszać awarię produkcyjną.
- L10: po zgodzie na uśpienie zapisać stan, uśpić i wybudzić Maca. Sprawdzić natychmiastowe stale oraz nowy odczyt/baseline, również gdy źródło było w backoffie. Nie przypisywać wyniku buforowanego sprzed sleep do świeżych danych.
- L11/L12: na dwóch monitorach przeciągnąć panel z większego na mniejszy, zmienić rozdzielczość, odłączyć monitor. Sprawdzić ≤40% widocznej wysokości, dostępność całości po scrollu i pozycję po restarcie. Dużą liczbę agentów przygotować tylko w odizolowanej sesji za zgodą; nie uruchamiać fikcyjnych agentów w sesji użytkownika bez niej.
- L13: włączyć VoiceOver za zgodą, przejść po sekcjach/licznikach/OK, następnie odczekać kilka odczytów bez zmian; brak zbędnych ogłoszeń. Przywrócić poprzednie ustawienie VoiceOver.
- L15: powtórzyć build/self-check i L1–L4 na dostępnych macOS 13 i Intel, zapisując dokładne środowisko; brak sprzętu oznacza test niewykonany.

## Sprzątanie

Quit helpera, zamknąć wyłącznie utworzone zakładki pluginu i potwierdzić brak jego procesów. Przywrócić poprzedni `machines.txt`; jeśli plugin dodano tylko do próby, po zatrzymaniu helpera wykonać `herdr plugin unlink local.status-overlay`. Nie usuwać katalogów stanu ani rejestracji istniejącego wcześniej pluginu bez dodatkowej zgody. Przywrócić ekran/rozdzielczość i VoiceOver. Istniejące sesje Herdr, agenci i master SSH pozostają nietknięte.

Po zaliczeniu usuwać odpowiednie pozycje z tej listy; dowody zapisywać w osobnym raporcie, nie jako historię wykonania tutaj.
