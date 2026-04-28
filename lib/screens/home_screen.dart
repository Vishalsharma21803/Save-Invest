import 'package:flutter/material.dart';

import '../constants/retailers.dart';
import '../models/retailer.dart';
import 'shopping_session_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SaveUp'), centerTitle: true),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 24),
            Text(
              'Where are you shopping today?',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            for (final retailer in kRetailers) ...[
              _RetailerCard(retailer: retailer),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }
}

class _RetailerCard extends StatelessWidget {
  const _RetailerCard({required this.retailer});

  final Retailer retailer;

  static const Map<RetailerId, IconData> _icons = {
    RetailerId.amazon: Icons.shopping_bag_outlined,
    RetailerId.ebay: Icons.storefront_outlined,
    RetailerId.walmart: Icons.local_grocery_store_outlined,
  };

  static const Map<RetailerId, Color> _colors = {
    RetailerId.amazon: Color(0xFFFF9900),
    RetailerId.ebay: Color(0xFF0064D2),
    RetailerId.walmart: Color(0xFF0071CE),
  };

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: _colors[retailer.id],
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      onPressed: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ShoppingSessionScreen(retailer: retailer),
          ),
        );
      },
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(_icons[retailer.id], size: 28),
          const SizedBox(width: 12),
          Text(
            retailer.name,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
