/// Where a witnessed arrival came from, such as `teams`.
///
/// This package witnesses arrivals for whatever host embeds it, not Teams
/// alone, so the set of sources is not this package's to close over: a
/// private constructor and [parse], not an enum, the same choice
/// `is_effects`'s `ProgramName` makes for program names.
final class ArrivalSource {
  const ArrivalSource._(this.value);

  /// [raw] as a source, or null when it is blank or holds whitespace.
  static ArrivalSource? parse(String raw) =>
      raw.isEmpty || raw.contains(RegExp(r'\s')) ? null : ArrivalSource._(raw);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is ArrivalSource && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
