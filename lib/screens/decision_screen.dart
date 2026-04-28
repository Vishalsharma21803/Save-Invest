import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/decision_type.dart';
import '../models/retailer.dart';

class DecisionScreen extends StatefulWidget {
  const DecisionScreen({
    super.key,
    required this.retailer,
    required this.decisionType,
  });

  final Retailer retailer;
  final DecisionType decisionType;

  @override
  State<DecisionScreen> createState() => _DecisionScreenState();
}

class _DecisionScreenState extends State<DecisionScreen> {
  final _amountController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _confirmed = false;

  String get _actionLabel =>
      widget.decisionType == DecisionType.save ? 'Save' : 'Invest';

  Color get _actionColor => widget.decisionType == DecisionType.save
      ? const Color(0xFF1E88E5)
      : const Color(0xFF8E24AA);

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  void _onConfirm() {
    if (_formKey.currentState?.validate() ?? false) {
      setState(() {
        _confirmed = true;
      });
    }
  }

  void _onDone() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('$_actionLabel Instead'),
        backgroundColor: _actionColor,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _confirmed
              ? _buildConfirmationView(context)
              : _buildAmountInputView(context),
        ),
      ),
    );
  }

  Widget _buildAmountInputView(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          Icon(
            widget.decisionType == DecisionType.save
                ? Icons.savings_outlined
                : Icons.trending_up_outlined,
            size: 72,
            color: _actionColor,
          ),
          const SizedBox(height: 24),
          Text(
            'How much were you about to spend on ${widget.retailer.name}?',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 28),
          TextFormField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              TextInputFormatter.withFunction((oldValue, newValue) {
                final pattern = RegExp(r'^\d*\.?\d{0,2}$');
                return pattern.hasMatch(newValue.text) ? newValue : oldValue;
              }),
            ],
            decoration: InputDecoration(
              labelText: 'Amount (USD)',
              prefixText: '\$ ',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: _actionColor, width: 2),
              ),
            ),
            validator: (value) {
              final trimmed = value?.trim() ?? '';
              if (trimmed.isEmpty) {
                return 'Please enter an amount';
              }

              final amount = double.tryParse(trimmed);
              if (amount == null || amount <= 0) {
                return 'Please enter a valid amount greater than zero';
              }

              return null;
            },
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _actionColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: _onConfirm,
            child: Text(
              'Confirm $_actionLabel',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfirmationView(BuildContext context) {
    final amount = double.parse(_amountController.text.trim());
    final formatted = '\$${amount.toStringAsFixed(2)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 32),
        const Icon(Icons.check_circle_outline, size: 96, color: Colors.green),
        const SizedBox(height: 20),
        Text(
          'Great choice!',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            color: _actionColor,
            fontWeight: FontWeight.w800,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Text(
          'Instead of spending $formatted on ${widget.retailer.name},\n'
          'you chose to $_actionLabel it.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: _actionColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _actionColor.withValues(alpha: 0.25)),
          ),
          child: Text(
            'The $_actionLabel flow will start from here.\n\n'
            '[PoC placeholder — actual $_actionLabel integration '
            'will be implemented in a future phase.]',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _actionColor,
              fontStyle: FontStyle.italic,
              fontSize: 15,
            ),
          ),
        ),
        const SizedBox(height: 32),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: _onDone,
          child: const Text(
            'Done',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}
