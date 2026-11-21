import 'package:chatminusis_components/chatminusis_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  test('durationLabel', () {
    expect(durationLabel(const Duration(seconds: 30)), '30 s');
    expect(durationLabel(const Duration(minutes: 5)), '5 min');
    expect(durationLabel(const Duration(hours: 2)), '2 h');
    expect(durationLabel(const Duration(days: 1)), '1 dia');
    expect(durationLabel(const Duration(days: 3)), '3 dias');
  });

  testWidgets('HiddenMessageBubble shows only its label and reports taps', (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(HiddenMessageBubble(label: 'Mensagem oculta', onTap: () => taps++)));
    expect(find.text('Mensagem oculta'), findsOneWidget);
    await tester.tap(find.text('Mensagem oculta'));
    expect(taps, 1);
    await tester.pumpWidget(host(const HiddenMessageBubble(label: 'Aguardando')));
    await tester.tap(find.text('Aguardando')); // no handler: nothing happens, no error
  });

  testWidgets('ErrorText renders nothing when empty', (tester) async {
    await tester.pumpWidget(host(const Column(children: [ErrorText(''), ErrorText('falhou')])));
    expect(find.text('falhou'), findsOneWidget);
    expect(find.byType(Text), findsOneWidget);
  });

  testWidgets('LoadingButton ignores taps while loading', (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(LoadingButton(label: 'Ok', onPressed: () => taps++)));
    await tester.tap(find.text('Ok'));
    expect(taps, 1);
    await tester.pumpWidget(host(LoadingButton(label: 'Ok', onPressed: () => taps++, loading: true)));
    await tester.tap(find.byType(FilledButton));
    expect(taps, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('confirmDialog is true only when confirmed', (tester) async {
    bool? result;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (c) => TextButton(
            onPressed: () async => result = await confirmDialog(c, title: 'T', message: 'M'),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirmar'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('RebuildAt rebuilds once when the instant passes', (tester) async {
    var builds = 0;
    final at = DateTime.now().add(const Duration(seconds: 5));
    await tester.pumpWidget(
      host(
        RebuildAt(
          instant: at,
          builder: (_) {
            builds++;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(builds, 1);
    await tester.pump(const Duration(seconds: 6));
    expect(builds, 2);
  });
}
