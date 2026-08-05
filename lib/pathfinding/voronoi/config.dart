/// Konfiguracja algorytmu Woronoja.
///
/// Wszystkie odległości w metrach (w lokalnym płaskim układzie XY).
library;

const List<String> kSmoothingModes = [
  'none',
  'chaikin',
  'shortcut',
  'shortcut+chaikin',
];

class VoronoiConfig {
  VoronoiConfig({
    this.blastRadius = 0.0,
    this.bodyClearance = 1.0,
    this.wallMineSpacing = 3.0,
    this.sealAllSides = false,
    this.portalMargin = 0.0,
    this.clipToField = true,
    this.smoothing = 'shortcut+chaikin',
    this.chaikinIterations = 3,
    this.smoothingClearanceRatio = 0.92,
    this.shortcutSamples = 24,
  }) {
    if (blastRadius < 0) {
      throw ArgumentError('blastRadius nie może być ujemny');
    }
    if (bodyClearance < 0) {
      throw ArgumentError('bodyClearance nie może być ujemny');
    }
    if (wallMineSpacing <= 0) {
      throw ArgumentError('wallMineSpacing musi być > 0');
    }
    if (!kSmoothingModes.contains(smoothing)) {
      throw ArgumentError('nieznany tryb wygładzania: $smoothing');
    }
    if (!(smoothingClearanceRatio > 0.0 && smoothingClearanceRatio <= 1.0)) {
      throw ArgumentError('smoothingClearanceRatio musi być w (0, 1]');
    }
  }

  // --- model zagrożenia ---

  /// Promień rażenia miny. Korytarz o wymaganym odstępie r od obudowy miny
  /// wymaga clearance r + blastRadius w grafie Woronoja.
  final double blastRadius;

  /// Wymagany odstęp operatora/drona od strefy rażenia. Ścieżka o clearance
  /// poniżej blastRadius + bodyClearance jest raportowana jako niebezpieczna.
  final double bodyClearance;

  // --- ściany pola ---

  /// Gęstość wirtualnych min rozsypanych po bokach pola (odległość między
  /// nimi). Mniejsza wartość = wierniejsze odwzorowanie ściany, więcej punktów.
  /// Powinna być <= tolerancji szerokości korytarza.
  final double wallMineSpacing;

  /// false: wirtualne miny tylko na bokach *nie* będących startem ani celem
  /// (korytarz jest otwarty na wejściu i wyjściu). true: obsypuje też
  /// start/cel -- przydatne tylko do testów.
  final bool sealAllSides;

  // --- graf ---

  /// Wierzchołek Woronoja jest kandydatem na wejście/wyjście, jeśli leży w
  /// obrębie pola i jego rzut na krawędź startową/końcową mieści się w niej.
  /// Margines rozluźnia ten warunek (metry poza krawędź).
  final double portalMargin;

  /// Odrzucaj krawędzie Woronoja wychodzące poza wielokąt pola. Wyłączenie
  /// pozwala ścieżce obejść pole zewnętrzem -- tylko do diagnostyki.
  final bool clipToField;

  // --- wygładzanie ---

  /// "none" | "chaikin" | "shortcut" | "shortcut+chaikin".
  final String smoothing;

  /// Liczba przebiegów Chaikina. Każdy przebieg ~podwaja liczbę punktów.
  final int chaikinIterations;

  /// Wygładzanie nie może obniżyć clearance ścieżki poniżej tego ułamka
  /// clearance ścieżki surowej. 1.0 = zero pogorszenia (mało wygładzi).
  final double smoothingClearanceRatio;

  /// Liczba próbek clearance na testowanym skrócie. Nieużywana: clearance
  /// odcinka liczony jest dokładnie (odległość mina-odcinek), więc wynik nie
  /// zależy od gęstości próbek. Pole zostaje dla zgodności konfiguracji.
  final int shortcutSamples;

  /// Minimalny bezpieczny odstęp od środka miny.
  double get requiredClearance => blastRadius + bodyClearance;
}
