# Backlog — znane ograniczenia i nierozwiązane kwestie

Stan po pierwszej implementacji pluginu i helpera. Nic tu nie jest zrobione.

## Do potwierdzenia w API

- **Etykiety:** helper używa `name` → `agent` → `pane_id` dla agenta i `workspace_id` dla workspace. Pole `name` nie zostało potwierdzone w schemacie 0.9.5 (jeśli go nie ma, nic się nie psuje). Nazwa workspace wymagałaby dodatkowego `workspace list` na źródło; poza planem.
- **Epoka serwera:** `agent list` nie zwraca `boot_id`/epoki. Restart serwera między dwoma udanymi odczytami jest wykrywany tylko przez cofnięcie `completion_seq` lub nowe `terminal_id`.
- **Format odpowiedzi:** parser oczekuje `{"result":{"agents":[…]}}` z `pane_id`, `agent_status`, opcjonalnie `terminal_id`, `workspace_id`, `completion_seq`, `agent`, `name`. Ustalone z próbek live koordynatora (local i `--machine`), nie ze schematu. Zmiana formatu da błąd „Niepoprawna odpowiedź API”, a nie błędne dane.
- **Lokalna sesja:** `agent list` dziedziczy `HERDR_SOCKET_PATH` z kontekstu pluginu; nie zweryfikowano przy sesjach nazwanych.

## Zachowanie helpera

- Brak auto-restartu: update/handoff/restart serwera Herdr zamyka panel pluginu i helper; trzeba ponownie uruchomić akcję.
- Odczyt po okresie nieaktualności (także samym przekroczeniu 6 s / 20 s bez błędu) jest nowym baseline: zakończenie, które wypadło w tej przerwie, nie trafi na listę `DONE`. Wybór zachowawczy (brak fałszywych zakończeń).
- Odpowiedź bez `completion_seq` po `working` nie tworzy zakończenia, dopóki znacznik się nie pojawi.
- Błędy auth remote widać jako „Odczyt nieudany (kod N)” bez rozróżnienia przyczyny (stderr nie jest czytany).
- Pozycja panelu jest zapisywana w `HERDR_PLUGIN_STATE_DIR/panel.json`, nie w `UserDefaults` (brak bundle).
- `NSStatusItem` ma tekst „HSO” zamiast ikony.
- Wysokość panelu jest przeliczana tylko przy zmianie danych lub ekranów.

## Poza zakresem MVP (świadomie)

Przechodzenie do agenta, sterowanie oknami/Spaces, powiadomienia, sekcje per klient, deduplikacja źródeł, skanowanie wszystkich maszyn, `--remote`, autostart, `.app` bundle, notaryzacja.
