# Development
## Istniejące releasy
Aktualne .apk są w zakładce `Releases` na githubie.\
Na androidy działa `app_arm64-*-release.apk`

## Lokalny build
`flutter build apk --release --split-per-abi`

## Odpalanie aplikacji w debugu
Należy zainstalować fluttera i wszystkie potrzebne komponenty.
`flutter doctor` pozwala sprawdzić czego brakuje.

`flutter run` i wybór podłączonego urządzenia. Koniecznie musi to być telefon z androidem, aplikacja nie działa na iOS (TODO)

## Release
`git tag vx.y.z`\
`git push origin vx.y.z`

Po 20 minutach powinny pojawić się pliki .apk w releasie.
Artefakty są dostępne przez 90 dni.

# Komunikacja APP <-> ESP
Całość komunikacji odbywa się wiadomościami o składni:
`DEST/SRC;KOMENDA;ARG...`

`DEST` lub `SRC` może przyjmować wartości 1, 2, 3 i 4 - konkretne drony. Może też przyjąć wartość 0 (broadcast)

ESP po odebraniu komendy odbija ją po serialu do apki z dopiskiem `ACK;` na początku wiadomości.

Koordynaty przychodzące są przesyłane przez ESP do apki w formacie`SRC;TM_POINTS;lat1;lon1;lat2;lon2...`

## Komendy
`START` - wznieś się
`CRD_SND;lat1;lon1;...;lat4;lon4` - transmisja punktów granicznych pola misji
`FLY_TO;lat;lon` - leć na te koordynaty
`ALT_SET;m` - Wzleć na `m` metrów
`MSN_START` - Rozpocznij misję
`END` - power down