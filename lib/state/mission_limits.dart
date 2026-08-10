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

/// Separation to keep between drones when they fly off-step.
///
/// The wire carries no GPS accuracy, so this is the operator's judgement, not a
/// derived number: it has to cover fix error, the airframe, and how loosely the
/// drone tracks a line. The floor is deliberately not zero -- "no clearance" is
/// not a setting anybody should be able to choose by accident.
const demoClearanceRange = NumberRange(min: 1.0, max: 20.0, step: 0.5);

/// Seconds a drone stands on a vertex, after it has been seen to arrive, before
/// the next step is sent. Zero is a legitimate setting -- it is how the demo
/// flew before the pause existed -- so this range starts there.
const demoSettleRange = NumberRange(min: 0.0, max: 10.0, step: 0.5);
const mainAltitudeRange = NumberRange(min: 0.5, max: 30.0, step: 0.5);
