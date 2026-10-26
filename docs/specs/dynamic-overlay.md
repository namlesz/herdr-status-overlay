# Minimalistyczny overlay — projekt wyglądu (v2)

Zasada: widać, kto pracuje, kto jest zablokowany i kto skończył. Bezczynni są tylko liczeni.
Żadnych przycisków, żadnych nagłówków trybu.

## Statusy agenta

| Status | Kiedy | Ikona (SF Symbol) | Kolor | Tekst |
|---|---|---|---|---|
| working | serwer `working` | `circle.fill` | `systemBlue` | `in progress` |
| blocked | serwer `blocked` | `exclamationmark.triangle.fill` | `systemYellow` | `blocked` |
| done | serwer `done` **albo** wzrost `completion_seq` po `working` (istniejący `CompletionTracker`) | `checkmark.circle.fill` | `systemGreen` | `done` |
| idle | pozostałe `idle`/`done` | — (tylko licznik) | — | — |
| unknown | serwer `unknown` | — (tylko licznik) | — | — |

„Skończył” znika sam: gdy agent znów zaczyna pracę, albo po 10 minutach od wykrycia zakończenia
(`SourceConfig`/stała `finishedTTL = 600 s`, liczona zegarem `now` przekazywanym do `Store`).
Usuwamy przycisk OK, `acknowledge` (Store, tracker, AppController, callback panelu) i stopkę o DONE.
Fałszywe „skończył” są akceptowane.

## Dane agenta (parser)

Do `AgentRecord` dochodzą (opcjonalne, przez `Text.label`, puste → nil):
- `place`: ostatni komponent ścieżki z `cwd` (np. `herdr-status-overlay`); brak → `workspace_id`.
- `activity`: `terminal_title_stripped`; pomijamy, gdy pusty.
Nazwa agenta: `agent` (rodzaj, np. `claude`, `pi`) → `name` → `pane_id`. Zła wartość tych pól typu
nie-string nadal odrzuca snapshot, jak dziś.

## Układ

Panel szerszy i czytelniejszy: szerokość **420**, karta per źródło (ciemna, jak dziś, odstęp 8).

```
┌────────────────────────────────────────────────┐
│ Lokalnie                    1 working · 3 idle  │  15 pt bold / 13 pt kolorowe liczniki
│ ● claude  herdr-status-overlay                  │  14 pt: ikona, nazwa (bold), miejsce (secondary)
│   Dynamiczny wygląd pluginu pi (MCP)            │  12 pt secondary, 1 linia, ucinana
│ ⚠ pi  finance                    zablokowany    │  tekst statusu po prawej w kolorze statusu
│ ✓ claude  platform-gitops            skończył   │
└────────────────────────────────────────────────┘
```

- Nagłówek: etykieta źródła + liczniki tylko niezerowe (`working`, `blocked`, `done`, `idle`, `unknown`),
  kolory jak statusy, idle/unknown secondary. 0 agentów → `brak agentów`.
- Wiersze: tylko working, blocked, done. Kolejność: blocked, working, done, potem miejsce, nazwa, klucz.
- Linia aktywności tylko gdy `activity` istnieje i różni się od nazwy.
- Dane nieaktualne: etykieta źródła secondary + ` — dane nieaktualne`, liczniki `—`, wiersze szare,
  opis problemu pod nagłówkiem (`describe(problem)` bez zmian).
- Usuwamy `SectionMode.swift` i jego testy (nagłówki trybu i odmiana nie są już używane).

## Bez zmian

Odczyty, `Poller`, `ProcessRunner`, pozycja i zapis stanu panelu, limit wysokości 40%, plugin i `bin/`.

Teksty UI po angielsku; font JetBrains Mono, a gdy brak — systemowy.
Nagłówek: liczniki jako kolorowe ikony statusu z liczbą (idle = `moon.fill`, unknown = `questionmark.circle`), słowa tylko w tooltipie. Wiersze bez tekstu statusu — status niesie ikona.
