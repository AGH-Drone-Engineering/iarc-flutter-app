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

# APP <-> ESP Communication
Entirety of communication is performed using following syntax:\
`<DEST/SRC><COMMAND><ARG...>`

`DEST/SRC` is an int8 with values from:
- `0x01` - bajer 1
- `0x02` - bajer 2
- `0x03` - bajer 3
- `0x04` - bajer 4
- `0x7F` - broadcast

`COMMAND` is an uint8 with these values:
- `0x01` - start
- `0x02` - crdSnd
- `0x03` - flyTo
- `0x04` - altSet
- `0x05` - msnStart
- `0x06` - end
- `0x07` - prepare for test flight
- `0x08` - prepare for mission
- `OxFF` - reserved for ESP to APP communication

ESP after receiving a command returns it to the app after flipping the initial bit (subtracting 128).

start, msnStart and end are argumentless commands.

flyTo has two 32-bit floats containing latitude and longitude

altSet has one 32-bit float containing altitude

crdSnd has 4 pairs of 32-bit floats containing latitude and longitude of 4 points.

ESP can, apart from ACKs, send a point. The command is then set as `0xFF`, after that there are two 32-bit floats.
