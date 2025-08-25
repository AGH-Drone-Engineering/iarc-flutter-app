# Development
## Istniejące releasy
Aktualne .apk są w zakładce `Releases` na githubie.
Na androidy działa `app_arm64-*-release.apk`

## Lokalny build
`flutter build apk --release --split-per-abi`

## Odpalanie aplikacji w debugu
Należy zainstalować fluttera i wszystkie potrzebne komponenty.
`flutter doctor` pozwala sprawdzić czego brakuje.

`flutter run` i wybór podłączonego urządzenia. Koniecznie musi to być telefon z androidem, aplikacja nie działa na iOS (TODO)

## Release
`git tag vx.y.z`
`git push origin vx.y.z`
Po 20 minutach powinny pojawić się pliki .apk w releasie.
Artefakty są dostępne przez 90 dni.

# Opis datagramów TM/TC
## Koordynaty
### Telemetry
`$call_sgn;CRD_TM_START;$coord_amt`
`$call_sgn;CRD_TM_POINT;$coord_id;$lat;$long`
`$call_sgn;CRD_TM_END`

`$call_sgn` - wartości: b1, b2, b3, b4 itd...
`$coord_amt` - liczba min rozpoznanych przez drona
`$coord_id` - dron każdemu punktowi przypisuje jakiś numer, od 1 w górę

### Telecommand
`$call_sgn;CRD_TC_START` - dron `$call_sgn` powinien rozpocząć transmisje
    Od razu po otrzymaniu każdy dron powinien przesłać CRD_TM_START z liczbą punktów
`$call_sgn;CRD_TC_RPT;$coord_id;$coord_id;...` - powtarzanie punktów w razie błędów transmisji

## Start dronów
### Telecommand
`$call_sgn;START` - wzleć na hardcoded wysokość
### Telemetry
`$call_sgn;START_ACK`

## Przesłanie koordynatów pola (przed konkursem, przydatne do testów ig)
### Telecommand
`$call_sgn;CRD_SND;$lat1;$lon1;$lat2;$lon2;$lat3;$lon3;$lat4;$lon4` - wzleć na wcześniej zadaną wysokość
### Telemetry
`$call_sgn;CRD_ACK`

## Przeleć x metrów
### Telecommand
`$call_sgn;FLY_TO;$lat;$lon` - leć do `$lat` `$lon`
### Telemetry
`$call_sgn;FLY_ACK`

## Wzleć na x
### Telecommand
`$call_sgn;ALT_SET;$m` - Wzleć na `$m` (float) metrów. 
### Telemetry
`$call_sgn;ALT_ACK`

## Rozpocznij misję
### Telecommand
`$call_sgn;MSN_START` - Rozpocznij skanowanie
### Telemetry
`$call_sgn;MSN_START_ACK` 

## Wyląduj
### Telecommand
`$call_sgn;MSN_END` - Power down
### Telemetry
`$call_sgn;MSN_END_ACK` 
