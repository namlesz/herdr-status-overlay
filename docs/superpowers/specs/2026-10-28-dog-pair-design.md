# Animacje pary psów

## Uzgodniony zakres
Użytkownik zatwierdził realizację gotowych animacji grupowych zamiast osobnych sterowanych postaci. Maksymalnie dwa psy. Pierwszy zachowuje zatwierdzony kremowy wygląd, drugi bazuje na dostarczonym zdjęciu papillona i ma około połowy wysokości pierwszego. Brak nowych zależności, zmian protokołu i restartowania działającej aplikacji.

## Zachowanie
- Liczymy tylko pracujących agentów w świeżych, wyświetlanych źródłach.
- Zero: obecny pies śpi; jeden: obecne zabawy solo; co najmniej dwóch: wejście drugiego psa, potem wspólne zabawy.
- Po spadku poniżej dwóch drugi pies wybiega, potem pierwszy wraca do odpowiedniego stanu, także snu przy zerze.
- Obecny STOP i jego pierwszeństwo pozostają bez zmian. Zachowujemy istniejące przejściowe świętowanie ukończenia.
- Zmiana Spaces: tylko pierwszy pies robi istniejący przewrót. Nie generujemy przewrotu pary.
- Reduce Motion nie odtwarza przejść ani ruchu; para ma statyczną klatkę.
- Osiem zabaw: gonitwa, przeciąganie sznura, wspólny aport, siłowanie na niby, skakanie wokół siebie, kopanie, pluskanie i podkradanie zabawki z pościgiem.
- Losujemy pełną pulę bez powtórzeń, również na granicy pul.
- Nagłe zmiany liczby agentów oraz przerwania STOP/Spaces nie mogą zostawić starej pary na ekranie.

## Rozważone podejścia
1. Niezależnie sterowane psy: łatwe dodawanie liczebności, ale znacznie trudniejsza koordynacja i mniej naturalne interakcje.
2. Gotowe sceny dla 1–4 psów: dużo dodatkowej grafiki i przejść.
3. Wybrane: obecny pies solo plus gotowe sceny pary, wejście i wyjście. Mały, zamknięty zakres grafiki i prosty automat stanów.

## Realizacja i weryfikacja
Zachowujemy obecny AppKit, zasoby PNG i historyczny katalog Corgi. Nowe sekwencje mają wspólne kadrowanie zachowujące ruch. Przygotowanie nowych zasobów nie może przeskalować istniejących klatek. Logika liczebności, przejść, losowania i Reduce Motion otrzymuje headless self-checki. Sprawdzamy plansze klatek na jasnym i ciemnym tle, swift run OverlaySelfCheck, kontrolę layoutu i kompilację release. Bez uruchamiania GUI bez zgody.

Ryzyko: generowane klatki mogą wymagać poprawek tożsamości, proporcji lub ciągłości ruchu. Nie deklarujemy wizualnego testu działającego overlaya na podstawie samej planszy.


## Rozmiar sceny psa
Menu `HSO` zawiera tylko własny rozmiar psa: `Dog scale: 100%…`, edytowany jako całkowita wartość 25–300%. Domyślne 100% zachowuje dotychczasowe 96 pt. Skala obejmuje wyłącznie scenę psa (w tym pozycję, unoszenie i litery snu), nigdy chmurkę, tekst ani karty. Wartość jest zapisywana w `panel.json`; brak lub nieprawidłowa wartość w starszym/uszkodzonym pliku daje 100%. Na małych ekranach widoczna scena może być ograniczona, by zmieścić się w szerokości i limicie 40% wysokości panelu; pozycja narożnika psa pozostaje zakotwiczona.
