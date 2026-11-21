import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/features/messaging/presentation/verify_view.dart';

void main() {
  test('safety number is shown as 3 lines of 4 groups of 5 digits', () {
    final n = List.generate(60, (i) => '${i % 10}').join();
    final lines = SafetyNumberView.format(n).split('\n');
    expect(lines, hasLength(3));
    expect(lines.first, '01234  56789  01234  56789');
  });
}
