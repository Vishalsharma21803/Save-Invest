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
  static const double _fallbackStripHeight = 58;
  final GlobalKey _stripKey = GlobalKey();
  bool _sessionActive = false;
  bool _isClosing = false;
  bool _didNavigateAway = false;
  double _stripHeight = _fallbackStripHeight;
  int _pointerDownCount = 0;
  int _payTapCount = 0;
  int _saveTapCount = 0;
  int _investTapCount = 0;
  int _closeTapCount = 0;

  void _log(String message) {
    debugPrint('$_tag $message');
  }

  @override
  void initState() {
    super.initState();
    _log('initState retailer=${widget.retailer.name}');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _logStripMetrics();
      _startSession();
    });
  }

  void _logStripMetrics() {
    final context = _stripKey.currentContext;
    if (context == null) {
      _log('strip metrics unavailable');
      return;
    }

    final box = context.findRenderObject() as RenderBox?;
    if (box == null) {
      _log('strip render box unavailable');
      return;
    }

    final size = box.size;
    final globalTopLeft = box.localToGlobal(Offset.zero);
    _stripHeight = size.height;
    _log(
      'strip size=${size.width.toStringAsFixed(1)}x${size.height.toStringAsFixed(1)} '
      'topLeft=(${globalTopLeft.dx.toStringAsFixed(1)},${globalTopLeft.dy.toStringAsFixed(1)})',
    );
  }

  Future<void> _startSession() async {
    if (!mounted) {
      return;
    }

    setState(() {
      _sessionActive = true;
    });
    _log('sessionActive=true, launching browser');

    final endReason = await ShoppingSessionService.startSession(
      context: context,
      url: widget.retailer.url,
      stripHeight: _stripHeight,
    );
    _log('startSession completed reason=$endReason');

    if (!mounted) {
      return;
    }

    setState(() {
      _sessionActive = false;
    });
    _log(
      'sessionActive=false didNavigateAway=$_didNavigateAway isClosing=$_isClosing',
    );
    final debug = ShoppingSessionService.getAndroidSessionDebugSnapshot();
    _log(
      'session-summary reason=$endReason '
      'browser=${debug.browserPackage ?? 'n/a'} '
      'stripHeight=${_stripHeight.toStringAsFixed(1)} '
      'sheetHeight=${debug.sheetHeight?.toStringAsFixed(1) ?? 'n/a'} '
      'pointerDown=$_pointerDownCount '
      'pay=$_payTapCount save=$_saveTapCount invest=$_investTapCount x=$_closeTapCount '
      'closeCallbacks=${debug.closeCallbacks} '
      'earlyCloseSuspicious=${debug.earlyCloseSuspicious} '
      'state=${debug.state}',
    );

    if (_didNavigateAway || _isClosing) {
      return;
    }

    switch (endReason) {
      case SessionEndReason.userDismissed:
        if (Platform.isAndroid &&
            _pointerDownCount == 0 &&
            _payTapCount == 0 &&
            _saveTapCount == 0 &&
            _investTapCount == 0 &&
            _closeTapCount == 0 &&
            debug.closeCallbacks > 0) {
          await _showUnsupportedAndReturnHome();
          return;
        }
        _returnHome();
      case SessionEndReason.closedByApp:
        break;
      case SessionEndReason.unsupportedPartialCustomTabs:
        await _showUnsupportedAndReturnHome();
      case SessionEndReason.launchFailed:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to open retailer right now.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 800));
        _returnHome();
    }
  }

  Future<void> _onPayTapped() async {
    if (!mounted) {
      return;
    }
    _payTapCount++;
    _log('PAY tapped, sessionActive=$_sessionActive');

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Pay stays in shopping mode for this PoC.'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _onDecisionTapped(DecisionType decisionType) async {
    if (_isClosing || !mounted) {
      _log('Decision ignored closing=$_isClosing mounted=$mounted');
      return;
    }
    if (decisionType == DecisionType.save) {
      _saveTapCount++;
    } else {
      _investTapCount++;
    }
    _log('${decisionType.name.toUpperCase()} tapped, closing browser');

    setState(() {
      _isClosing = true;
      _didNavigateAway = true;
    });

    await ShoppingSessionService.endSession();

    if (!mounted) {
      return;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => DecisionScreen(
          retailer: widget.retailer,
          decisionType: decisionType,
        ),
      ),
    );
  }

  Future<void> _onCloseTapped() async {
    if (_isClosing || !mounted) {
      _log('X ignored closing=$_isClosing mounted=$mounted');
      return;
    }
    _closeTapCount++;
    _log('X tapped, closing browser');

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
    _log('Back pressed sessionActive=$_sessionActive isClosing=$_isClosing');
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
      _log(
        'returnHome ignored mounted=$mounted didNavigateAway=$_didNavigateAway',
      );
      return;
    }

    _didNavigateAway = true;
    _log('returnHome pop');
    Navigator.of(context).pop();
  }

  Future<void> _showUnsupportedAndReturnHome() async {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'This device/browser cannot support interactive Partial Custom Tabs for this PoC.',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    _returnHome();
  }

  @override
  void dispose() {
    _log('dispose');
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
              Container(
                key: _stripKey,
                color: Colors.black,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (event) {
                    _pointerDownCount++;
                    _log(
                      'pointerDown x=${event.position.dx.toStringAsFixed(1)} '
                      'y=${event.position.dy.toStringAsFixed(1)} '
                      'sessionActive=$_sessionActive',
                    );
                  },
                  onPointerUp: (event) {
                    _log(
                      'pointerUp x=${event.position.dx.toStringAsFixed(1)} '
                      'y=${event.position.dy.toStringAsFixed(1)}',
                    );
                  },
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
                        onPressed: _isClosing
                            ? null
                            : () => _onDecisionTapped(DecisionType.save),
                      ),
                      const SizedBox(width: 8),
                      _SessionButton(
                        label: 'INVEST',
                        color: const Color(0xFF8E24AA),
                        onPressed: _isClosing
                            ? null
                            : () => _onDecisionTapped(DecisionType.invest),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    _sessionActive
                        ? 'Opening ${widget.retailer.name}...'
                        : 'Session closed',
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
