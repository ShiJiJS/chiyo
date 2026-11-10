/// Presets for new owner approvals and newly submitted pending requests.
/// Persisted deadlines remain facts; changing these never rewrites old grants.
abstract final class AccessTiming {
  static const defaultMinutes = 120;
  static const defaultLifetime = Duration(hours: 2);
  static const grantMinutes = [120, 240, 480, 1440];
  static const waitingMinutes = [30, 60, 120, 240, 480, 1440];

  static bool isGrant(Duration lifetime) =>
      grantMinutes.any((m) => lifetime == Duration(minutes: m));
  // Preserve explicit legacy commands and receipt replay. New editors only
  // offer grantMinutes; accepting an old command never changes its deadline.
  static bool acceptsCredentialLifetime(
    Duration? lifetime, {
    required bool sessionValidity,
  }) => lifetime == null
      ? sessionValidity
      : isGrant(lifetime) ||
            const [15, 30].any((m) => lifetime == Duration(minutes: m));

  static bool acceptsFieldLifetime(
    Duration lifetime, {
    required int protocolVersion,
  }) =>
      isGrant(lifetime) ||
      (protocolVersion == 2 ? const [15, 30, 60] : const [15, 30]).any(
        (m) => lifetime == Duration(minutes: m),
      );

  static bool acceptsOrganizationLifetime(Duration lifetime) =>
      isGrant(lifetime) ||
      lifetime > Duration.zero && lifetime <= const Duration(minutes: 30);
}
