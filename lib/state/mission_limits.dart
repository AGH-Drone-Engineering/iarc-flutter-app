/// Bounds for the mission numbers the operator can change.
///
/// One definition shared by the steppers on the mission tab, the [AppState]
/// setters and the voice parser. A spoken "ustaw promień na sto" has no button
/// to stop at the end of its travel, so the clamp has to live somewhere both
/// paths reach.
class NumberRange {
  const NumberRange({required this.min, required this.max, required this.step});

  final double min;
  final double max;
  final double step;

  double clamp(double v) => v.clamp(min, max).toDouble();
}

const demoAltitudeRange = NumberRange(min: 0.5, max: 30.0, step: 0.5);
const demoVerticesRange = NumberRange(min: 3, max: 16, step: 1);
const demoRadiusRange = NumberRange(min: 1.0, max: 25.0, step: 0.5);
const mainAltitudeRange = NumberRange(min: 0.5, max: 30.0, step: 0.5);
