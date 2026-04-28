import 'package:flutter_test/flutter_test.dart';

import 'package:saveup_poc/app.dart';
import 'package:saveup_poc/models/decision_type.dart';
import 'package:saveup_poc/models/retailer.dart';
import 'package:saveup_poc/screens/decision_screen.dart';
import 'package:flutter/material.dart';

void main() {
  testWidgets('home screen shows all retailers', (tester) async {
    await tester.pumpWidget(const SaveUpApp());

    expect(find.text('Amazon'), findsOneWidget);
    expect(find.text('eBay'), findsOneWidget);
    expect(find.text('Walmart'), findsOneWidget);
  });

  testWidgets('decision screen validates empty amount', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DecisionScreen(
          retailer: Retailer(
            id: RetailerId.amazon,
            name: 'Amazon',
            url: 'https://www.amazon.com',
          ),
          decisionType: DecisionType.save,
        ),
      ),
    );

    await tester.tap(find.text('Confirm Save'));
    await tester.pumpAndSettle();

    expect(find.text('Please enter an amount'), findsOneWidget);
  });

  testWidgets('decision screen confirms valid amount', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DecisionScreen(
          retailer: Retailer(
            id: RetailerId.walmart,
            name: 'Walmart',
            url: 'https://www.walmart.com',
          ),
          decisionType: DecisionType.invest,
        ),
      ),
    );

    await tester.enterText(find.byType(TextFormField), '49.99');
    await tester.tap(find.text('Confirm Invest'));
    await tester.pumpAndSettle();

    expect(find.text('Great choice!'), findsOneWidget);
    expect(find.textContaining('you chose to Invest it'), findsOneWidget);
  });
}
