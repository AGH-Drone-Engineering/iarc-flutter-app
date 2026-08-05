import 'package:flutter/material.dart';

import 'path/clearance_view.dart';
import 'path/grid_path_view.dart';

/// Wyznaczanie przejścia przez pole minowe.
///
/// Dwie zakładki, bo to dwa różne pytania:
///
/// * **Siatka** -- ścieżka punktowana wg spec.txt, na siatce 2x2 stopy. To ona
///   trafia do path.txt.
/// * **Odstęp** -- ścieżka maksymalizująca odległość od najbliższej miny, w
///   przestrzeni ciągłej. Nie jest punktowana, ale odpowiada na pytanie, czy w
///   ogóle istnieje bezpieczny korytarz, niezależnie od dyskretyzacji.
class PathTab extends StatelessWidget {
  const PathTab({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.grid_on), text: 'Siatka'),
              Tab(icon: Icon(Icons.social_distance), text: 'Odstęp'),
            ],
          ),
          const Expanded(
            child: TabBarView(
              children: [GridPathView(), ClearanceView()],
            ),
          ),
        ],
      ),
    );
  }
}
