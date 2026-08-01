# IARC 2026 — aplikacja stacji naziemnej

Flutter (Android). Steruje dronami przez płytkę ESP podłączoną po USB.

```
Telefon ──USB──► ESP naziemny ──LoRa──► HAT drona ──UART──► Raspberry Pi
```

Protokół: **[PROTOCOL.md](PROTOCOL.md)**.

## Transport

Dwie drogi do dronów, przełączane **w działającej aplikacji** (zakładka Link),
bez rebuildu. Protokół misji jest identyczny — różni się tylko łącze.

| | LoRa (USB) | UDP (Wi-Fi) |
|---|---|---|
| Droga | telefon → ESP → LoRa → HAT → Pi | telefon → Wi-Fi → Pi |
| Ramkowanie | LoRaCom + CRC16 | jeden komunikat = jeden datagram |
| Odbiór | polling `GETMSG` co 200 ms | push |

> HAT mostkuje LoRaCom na GPIO17/18, nie na USB-CDC. Do czasu zmiany firmware'u
> telefon podłączamy przez przejściówkę USB-UART do tych pinów.

**UDP** to zapas na wypadek niegotowej płytki ESP. W zakładce Link ustawia się port
nasłuchu i `host:port` per dron — hostname (np. `raspi-usa-1.local`) albo IP,
rozwiązywane przy połączeniu. Konfiguracja jest zapamiętywana. Dron rozpoznawany
po adresie źródłowym, więc każdy musi mieć własny; datagram z nieznanego hosta
trafia do logów jako ostrzeżenie.

## Zakładki

| | |
|---|---|
| **Mission** | Sterowanie misją, postęp demo, status floty, alerty braku ACK |
| **Map** | Pozycje dronów, ślad, miny, pole misji |
| **Field** | 4 narożniki pola (dowolna kolejność) |
| **Logs** | Logi |
| **Link** | Połączenie USB, diagnostyka |

## Komendy

| Komenda | Parametry |
|---|---|
| `START_DEMO` | wysokość zawisu |
| `NEXT_STEP` | — |
| `START_MAIN` | 4 narożniki + wysokość |
| `MOVE` | kierunek + dystans |
| `LAND` / `RTH` / `STATUS` | — |
| `KILL` | — |

## Misja demo

Po `START_DEMO` aplikacja prowadzi sekwencję sama, bez udziału operatora:

```
ACK          → NEXT_STEP
brak ACK     → RTH
NACK         → RTH
MISSION_DONE → koniec
```

Każdy dron ma własny stan i licznik kroków; postęp widać w zakładce Mission.
Limit 200 kroków jako bezpiecznik. `Stop` przerywa sekwencję bez wysyłania RTH.

D-pad pod sekwencją wysyła pojedyncze `MOVE` — sterowanie ręczne, niezależne
od autopilota.

## ACK

Każda komenda ma numer sekwencyjny, dron odpowiada `ACK`/`NACK` z tym numerem
w ciągu 2 s. Po 3 próbach (ten sam numer, więc dron może odfiltrować duplikat)
operator dostaje alert. Broadcast śledzony per dron.

## KILL

Przytrzymanie 1 s. Unicast do każdego drona, 3×, bez czekania na ACK.

> Łańcuch KILL nie jest zamknięty: Pi ignoruje sygnał, ESP nie sprawdza payloadu,
> piny killswitcha są na stałe `HIGH` (commit `fd6abd2`). Aplikacja robi swoją
> połowę — druga musi powstać.

## Logi

Trwałe, dzielone per uruchomienie aplikacji (JSONL, 20 ostatnich sesji).

- Wybór sesji z listy, starsze wczytywane z dysku na żądanie
- Poziomy: `TRACE`, `INFO`, `SENT`, `RECV`, `WARN`, `ERROR` — filtr wielokrotny
- Filtr tekstowy po treści i tagu (`link`, `udp`, `ack`, `demo`, `app`)
- `Copy` kopiuje aktualnie przefiltrowane wpisy wybranej sesji
- Wpisy dłuższe niż 3 linie zwinięte, z `expand` / `collapse`
- `TRACE` domyślnie zbierany, ale ukryty; przełącznik `Capture trace` wyłącza
  zbieranie (przy 5 pollach/s to ~20 linii/s)

## Komendy głosowe

Na początku może wystąpić desygnacja drona (`dron 2`, `wszystkie`, `Bajer 3`).
`KILL` celowo niedostępny głosowo.

| Intencja | Przykłady |
|---|---|
| `START_DEMO` | „start demo", „rozpocznij misję demo" |
| `START_MAIN` | „start misję główną", „run field mission" |
| `LAND` | „ląduj", „land" |
| `RTH` | „wracaj", „do domu", „return" |
| `STATUS` | „status", „raport", „ping" |
| `MOVE` | „w przód 5 m", „forward left", „back 3 meters" |

# Development

```bash
flutter test        # 74 testy
flutter analyze
flutter build apk --release --split-per-abi
```

`flutter run` i wybór urządzenia — tylko Android, iOS nie działa (TODO).

Release: `git tag vx.y.z && git push origin vx.y.z`, .apk pojawia się po ~20 min.
