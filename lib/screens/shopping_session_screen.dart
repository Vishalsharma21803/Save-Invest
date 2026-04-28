import 'dart:io';

import 'package:flutter/material.dart';

import '../models/decision_type.dart';
import '../models/retailer.dart';
import '../models/session_end_reason.dart';
import '../services/shopping_session_service.dart';
import 'decision_screen.dart';

class ShoppingSessionScreen extends StatefulWidget {
  const ShoppingSessionScreen({super.key, required this.retailer});

  final Retailer retailer;

  @override
  State<ShoppingSessionScreen> createState() => _ShoppingSessionScreenState();
}

class _ShoppingSessionScreenState extends State<ShoppingSessionScreen> {
  static const String _tag = '[SaveUp][SessionScreen]';
  bool _sessionActive = false;
  bool _isClosing = false;
  bool _didNavigateAway = false;

  void _log(String message) {
    debugPrint('$_tag $message');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startSession();
    });
  }

  Future<void> _startSession() async {
    if (!mounted) {
      return;
    }
    setState(() => _sessionActive = true);
    _log('sessionActive=true launching browser');

    final endReason = await ShoppingSessionService.startSession(
      context: context,
      url: widget.retailer.url,
      stripHeight: 0,
    );

    if (!mounted) {
      return;
    }

    setState(() => _sessionActive = false);
    _log('session finished reason=$endReason');

    if (_didNavigateAway || _isClosing) {
      return;
    }

    switch (endReason) {
      case SessionEndReason.actionSave:
        await _goDecision(DecisionType.save);
      case SessionEndReason.actionInvest:
        await _goDecision(DecisionType.invest);
      case SessionEndReason.userDismissed:
        _returnHome();
      case SessionEndReason.closedByApp:
        _returnHome();
      case SessionEndReason.unsupportedCustomTabs:
        await _showMessageAndReturnHome(
          'Custom Tabs is not supported on this device/browser.',
        );
      case SessionEndReason.launchFailed:
        await _showMessageAndReturnHome('Unable to open retailer right now.');
    }
  }

  Future<void> _showMessageAndReturnHome(String message) async {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
    await Future<void>.delayed(const Duration(milliseconds: 900));
    _returnHome();
  }

  Future<void> _goDecision(DecisionType type) async {
    if (_isClosing || !mounted) {
      return;
    }
    setState(() {
      _isClosing = true;
      _didNavigateAway = true;
    });
    if (!Platform.isAndroid) {
      await ShoppingSessionService.endSession();
    }
    if (!mounted) {
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) =>
            DecisionScreen(retailer: widget.retailer, decisionType: type),
      ),
    );
  }

  Future<void> _onPayTapped() async {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Pay stays in shopping mode for this PoC.'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _onCloseTapped() async {
    if (_isClosing || !mounted) {
      return;
    }
    setState(() {
      _isClosing = true;
      _didNavigateAway = true;
    });
    await ShoppingSessionService.endSession();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _handleBackPress() async {
    if (_isClosing) {
      return;
    }
    if (_sessionActive) {
      await _onCloseTapped();
      return;
    }
    _returnHome();
  }

  void _returnHome() {
    if (!mounted || _didNavigateAway) {
      return;
    }
    _didNavigateAway = true;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    ShoppingSessionService.unlockOrientation();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _handleBackPress();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              if (Platform.isIOS) _buildIosControlStrip(),
              Expanded(
                child: Center(
                  child: Text(
                    Platform.isAndroid
                        ? 'Use browser toolbar: PAY / SAVE / INVEST'
                        : (_sessionActive
                              ? 'Opening ${widget.retailer.name}...'
                              : 'Session closed'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIosControlStrip() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: _isClosing ? null : _onCloseTapped,
            icon: const Icon(Icons.close, color: Colors.white),
            tooltip: 'End session',
          ),
          const Spacer(),
          _SessionButton(
            label: 'PAY',
            color: const Color(0xFF43A047),
            onPressed: _isClosing ? null : _onPayTapped,
          ),
          const SizedBox(width: 8),
          _SessionButton(
            label: 'SAVE',
            color: const Color(0xFF1E88E5),
            onPressed: _isClosing ? null : () => _goDecision(DecisionType.save),
          ),
          const SizedBox(width: 8),
          _SessionButton(
            label: 'INVEST',
            color: const Color(0xFF8E24AA),
            onPressed: _isClosing
                ? null
                : () => _goDecision(DecisionType.invest),
          ),
        ],
      ),
    );
  }
}

class _SessionButton extends StatelessWidget {
  const _SessionButton({
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final Color color;
  final Future<void> Function()? onPressed;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        disabledBackgroundColor: color.withValues(alpha: 0.4),
        disabledForegroundColor: Colors.white70,
        minimumSize: const Size(72, 42),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: onPressed == null ? null : () => onPressed!.call(),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
