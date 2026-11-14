/// The part of `package:intl` the greeting uses, with output that tells it
/// from the hosted package's.
class NumberFormat {
  /// As intl's `NumberFormat.decimalPattern`.
  NumberFormat.decimalPattern([this.locale]);

  /// The locale asked for.
  final String? locale;

  /// Formats [number] with no grouping, and says whose it is.
  String format(num number) => '${number.toInt()} (forked intl)';
}
