/// Live device power signals used to decide whether on-device AI inference is
/// allowed right now. Kept as a plain value object so the *decision* stays a
/// pure, unit-testable function ([DevicePowerPolicy.allowsLocalInference]),
/// independent of how the values are read (battery plugin, platform channel…).
class DevicePowerSnapshot {
  /// Battery charge 0–100, or -1 when unknown/unsupported (e.g. desktop/web).
  final int batteryLevel;

  /// Whether the device is currently charging (or full / plugged in).
  final bool isCharging;

  /// Whether the OS battery-saver / low-power mode is on.
  final bool batterySaveMode;

  const DevicePowerSnapshot({
    required this.batteryLevel,
    required this.isCharging,
    required this.batterySaveMode,
  });

  /// A permissive snapshot used as a safe fallback when power state can't be
  /// read — never blocks features just because we lack information.
  static const DevicePowerSnapshot unknown = DevicePowerSnapshot(
    batteryLevel: -1,
    isCharging: false,
    batterySaveMode: false,
  );
}

/// Decides whether the app should run heavy on-device LLM inference given the
/// current power state. On-device inference is a sustained, power-hungry,
/// heat-generating workload, so we back off when the user is clearly trying to
/// conserve power. Cloud-routed tasks are unaffected; only the *local* path is
/// gated (see [AiRouter.route]'s `localInferenceAllowed`).
class DevicePowerPolicy {
  const DevicePowerPolicy._();

  /// Battery percentage at/below which we stop on-device inference when the
  /// device is not charging.
  static const int lowBatteryThreshold = 20;

  /// Pure decision: returns false (→ no local inference) when the user is
  /// saving power, or the battery is low and not charging. Unknown battery
  /// (`-1`) is treated as "fine" so unsupported platforms aren't penalised.
  static bool allowsLocalInference(DevicePowerSnapshot s) {
    if (s.batterySaveMode) return false;
    if (!s.isCharging &&
        s.batteryLevel >= 0 &&
        s.batteryLevel <= lowBatteryThreshold) {
      return false;
    }
    return true;
  }
}
