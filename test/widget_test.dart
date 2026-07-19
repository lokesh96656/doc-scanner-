import 'package:flutter_test/flutter_test.dart';

import 'package:docread_demo/app.dart';

void main() {
  testWidgets('App loads home page', (WidgetTester tester) async {
    await tester.pumpWidget(const App());

    expect(find.text('OCR Document Scanner'), findsOneWidget);
    expect(find.text('Scan ID'), findsOneWidget);
    expect(find.text('Selfie + ID'), findsOneWidget);
    expect(find.text('Scan ID (AWS Rekognition)'), findsOneWidget);
  });
}
