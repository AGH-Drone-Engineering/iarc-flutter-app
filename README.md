# Komendy głosowe 
Na początku komendy może wystąpić desygnacja. Można zmieniać komendę bez powtarzania jej
Jeśli komenda nie jest valid, nowa desygnacja nie zapisze się.

## Misja
W misji zaimplementowane po stronie raspi mają być:
- `0x03` FLY_TO - podaje punkt do wylądowania
- `0x02` CRD_SND - podaje koordynaty pola (należy wcześniej w zakładce inputs je wprowadzić)
- `0x01` START - sygnał do startu
- `0x06` END - sygnał do wylądowania

### FLY_TO
Możliwe teksty aktywacyjne (przykładowe):
- lat -52.1 lon 21.0
- latitude: minus 52.1, longitude: 21.0
- coordinates -52.1, 21.0
- coords: minus 52.1 21.0
- szer. -52.1 dl. 21.0
- szerokość: minus 52.1, długość: 21.0
- współrzędne -52.1, 21.0
- koordynaty: minus 52.1 21.0

### CRD_SND
Możliwe teksty aktywacyjne (przykładowe):
- send coords
- share coordinates
- broadcast location
- push position
- upload coords
- wyślij współrzędne
- prześlij koordynaty
- udostępnij pozycję
- prześlij lokalizację

### START
Możliwe teksty aktywacyjne (przykładowe):
- start
- arm
- begin
- startuj
- uzbrój
- zacznij
- rozpocznij

### END 
Możliwe teksty aktywacyjne (przykładowe):
- land
- touchdown
- descend
- ląduj
- wyląduj
- uziem
- uziemiaj

## Lot testowy
W trakcie lotu testowego dostępne są następujące komendy:
- `0x01` START
- `0x04` ALT_SET - ustawia wysokość lotu w m
- `0x09` FLY_POLAR - leć na koordynaty polarne wycentrowane na dronie (dist m, angle deg)
- `0x0B` SET_SPEED - ustawia prędkośc w m/s 
- `0x06` END

### ALT_SET
Możliwe teksty aktywacyjne (przykładowe):
- set altitude to 2m
- set alt to 4m
- height 2.1
- ustaw wys. na 5m
- ustaw wysokość lotu do 2.5m
- wysokość 2,1
- wys. do 1
- wys. 1

### FLT_POLAR
Możliwe teksty aktywacyjne (przykładowe):
- forward 30 m at minus 90 degrees
- move forward 30 meters bearing negative 24.5 degrees
- 1.2m heading -23
- leć do przodu 2m pod kątem 20 stopni
- przesuń 4m kąt minus 4 deg

### SET_SPEED
Możliwe teksty aktywacyjne (przykładowe):
- (set) speed to 5 (m/s)
- velocity 1
- ustaw prędkość 25477.2536m/s
- prędkość 2 metry na sekundę


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
