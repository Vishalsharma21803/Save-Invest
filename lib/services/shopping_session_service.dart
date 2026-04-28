import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_custom_tabs/flutter_custom_tabs.dart';

import '../models/session_end_reason.dart';

class ShoppingSessionService {
  ShoppingSessionService._();
  static const String _tag = '[SaveUp][SessionService]';

  static const MethodChannel _iosSafariSheetChannel = MethodChannel(
    'com.saveup.app/safari_sheet',
  );
  static const MethodChannel _androidCustomTabsChannel = MethodChannel(
    'com.saveup.app/custom_tabs',
  );
  static const int _retryAttempts = 5;
  static const Duration _retryInterval = Duration(milliseconds: 200);
  static const Duration _androidEarlyCloseThreshold = Duration(
    milliseconds: 450,
  );
  static const double _androidMinSheetFraction = 0.50;
  static const double _androidMaxSheetFraction = 0.90;

  static bool _closeRequestedByApp = false;
  static Completer<SessionEndReason>? _androidSessionCompleter;
  static bool _androidChannelHandlerRegistered = false;
  static _AndroidSessionState _androidSessionState = _AndroidSessionState.idle;
  static Stopwatch? _androidSessionStopwatch;
  static String? _androidBrowserPackage;
  static double? _androidLaunchedSheetHeight;
  static int _androidCloseCallbacks = 0;
  static bool _androidEarlyCloseSuspicious = false;

  static Future<SessionEndReason> startSession({
    required BuildContext context,
    required String url,
    required double stripHeight,
  }) async {
    _closeRequestedByApp = false;
    final mediaQuery = MediaQuery.of(context);
    _log(
      'startSession platform=${Platform.operatingSystem} '
      'url=$url size=${mediaQuery.size} padding=${mediaQuery.padding} '
      'stripHeight=${stripHeight.toStringAsFixed(1)}',
    );
    await _lockPortrait();

    try {
      if (Platform.isAndroid) {
        return await _launchAndroid(
          mediaQuery: mediaQuery,
          url: url,
          stripHeight: stripHeight,
        );
      }
      if (Platform.isIOS) {
        return await _launchIOS(url: url);
      }

      return SessionEndReason.launchFailed;
    } finally {
      await unlockOrientation();
      _closeRequestedByApp = false;
      _log('startSession finished; orientation unlocked');
    }
  }

  static Future<void> endSession() async {
    _closeRequestedByApp = true;
    _setAndroidState(_AndroidSessionState.closing, reason: 'endSession');
    _log('endSession requested by app');

    try {
      await closeCustomTabs();
      _log('closeCustomTabs completed');
    } finally {
      if (Platform.isAndroid) {
        _completeAndroidSession(SessionEndReason.closedByApp);
      }
      await unlockOrientation();
      _log('endSession finished; orientation unlocked');
    }
  }

  static Future<void> unlockOrientation() {
    return SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  static Future<void> _lockPortrait() {
    return SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
  }

  static Future<SessionEndReason> _launchAndroid({
    required MediaQueryData mediaQuery,
    required String url,
    required double stripHeight,
  }) async {
    _prepareAndroidSessionDebug();
    _setAndroidState(_AndroidSessionState.launching, reason: 'launch-start');
    try {
      final support = await _getAndroidCustomTabsSupport();
      _androidBrowserPackage = support.packageName;
      _log(
        'android preflight supported=${support.supported} '
        'package=${support.packageName} isChrome=${support.isChrome} '
        'reason=${support.reason}',
      );
      if (!support.supported) {
        debugPrint(
          '[SaveUp] Partial Custom Tabs unsupported: '
          '${support.reason ?? 'unknown reason'}',
        );
        return SessionEndReason.unsupportedPartialCustomTabs;
      }

      final uri = Uri.parse(url);
      final browserConfiguration = _createAndroidBrowserConfiguration(support);
      final sheetHeight = _androidSheetHeight(
        mediaQuery,
        stripHeight: stripHeight,
      );
      _androidLaunchedSheetHeight = sheetHeight;
      _log(
        'android launch uri=$uri '
        'sheetHeight=${sheetHeight.toStringAsFixed(1)} '
        'browserConfig=${browserConfiguration == null ? 'default(chrome)' : 'fallback'}',
      );

      final sessionClosed = _prepareAndroidSessionCloseWaiter();

      await launchUrl(
        uri,
        customTabsOptions: CustomTabsOptions.partial(
          configuration: PartialCustomTabsConfiguration.bottomSheet(
            initialHeight: sheetHeight,
            activityHeightResizeBehavior:
                CustomTabsActivityHeightResizeBehavior.fixed,
            cornerRadius: 16,
            backgroundInteractionEnabled: true,
          ),
          browser: browserConfiguration,
          showTitle: true,
        ),
      );
      _setAndroidState(_AndroidSessionState.active, reason: 'launch-returned');
      _log('android launchUrl returned; waiting for close callback');

      final reason = await sessionClosed;
      _setAndroidState(_AndroidSessionState.closed, reason: 'session-complete');
      _log('android session closed reason=$reason');
      return reason;
    } catch (error) {
      debugPrint('[SaveUp] Android session launch failed: $error');
      _log('android launch exception=$error');
      _setAndroidState(_AndroidSessionState.closed, reason: 'launch-exception');
      _completeAndroidSession(SessionEndReason.launchFailed);
      return SessionEndReason.launchFailed;
    }
  }

  static Future<_AndroidCustomTabsSupport>
  _getAndroidCustomTabsSupport() async {
    try {
      final support = await _androidCustomTabsChannel
          .invokeMapMethod<String, dynamic>('getPartialCustomTabsSupport');
      _log('android preflight raw response=$support');
      return _AndroidCustomTabsSupport.fromMap(support);
    } on MissingPluginException catch (error) {
      debugPrint('[SaveUp] Android Custom Tabs preflight missing: $error');
      return const _AndroidCustomTabsSupport(
        supported: false,
        reason: 'native preflight channel missing',
      );
    } on PlatformException catch (error) {
      debugPrint(
        '[SaveUp] Android Custom Tabs preflight failed: '
        '${error.message}',
      );
      return _AndroidCustomTabsSupport(supported: false, reason: error.message);
    }
  }

  static Future<SessionEndReason> _prepareAndroidSessionCloseWaiter() {
    _registerAndroidChannelHandler();
    final completer = Completer<SessionEndReason>();
    _androidSessionCompleter = completer;
    return completer.future;
  }

  static void _registerAndroidChannelHandler() {
    if (_androidChannelHandlerRegistered) {
      return;
    }

    _androidChannelHandlerRegistered = true;
    _log('registering android close callback handler');
    _androidCustomTabsChannel.setMethodCallHandler((call) async {
      _log('android channel callback method=${call.method}');
      if (call.method == 'partialCustomTabsClosed') {
        _androidCloseCallbacks++;
        final elapsed = _androidSessionStopwatch?.elapsed ?? Duration.zero;
        _log(
          'android close callback #$_androidCloseCallbacks '
          'state=$_androidSessionState elapsedMs=${elapsed.inMilliseconds}',
        );

        if (!_closeRequestedByApp &&
            (_androidSessionState == _AndroidSessionState.launching ||
                elapsed < _androidEarlyCloseThreshold)) {
          _androidEarlyCloseSuspicious = true;
          _log(
            'WARN early close callback detected '
            'state=$_androidSessionState elapsedMs=${elapsed.inMilliseconds}',
          );
          _completeAndroidSession(
            SessionEndReason.unsupportedPartialCustomTabs,
          );
          return;
        }

        _completeAndroidSession(
          _closeRequestedByApp
              ? SessionEndReason.closedByApp
              : SessionEndReason.userDismissed,
        );
      }
    });
  }

  static void _completeAndroidSession(SessionEndReason reason) {
    final completer = _androidSessionCompleter;
    if (completer == null || completer.isCompleted) {
      _log('completeAndroidSession ignored reason=$reason');
      return;
    }

    _log('completeAndroidSession reason=$reason');
    _androidSessionStopwatch?.stop();
    completer.complete(reason);
    _androidSessionCompleter = null;
  }

  static CustomTabsBrowserConfiguration? _createAndroidBrowserConfiguration(
    _AndroidCustomTabsSupport support,
  ) {
    if (support.isChrome) {
      return null;
    }

    final fallbackCustomTabs = support.packageName == null
        ? null
        : <String>[support.packageName!];

    return CustomTabsBrowserConfiguration(
      prefersDefaultBrowser: true,
      fallbackCustomTabs: fallbackCustomTabs,
    );
  }

  static double _androidSheetHeight(
    MediaQueryData mediaQuery, {
    required double stripHeight,
  }) {
    final screenHeight = mediaQuery.size.height;
    final safeStripHeight = stripHeight < 0 ? 0.0 : stripHeight;
    final targetHeight =
        screenHeight - mediaQuery.padding.top - safeStripHeight;
    final minHeight = screenHeight * _androidMinSheetFraction;
    final maxHeight = screenHeight * _androidMaxSheetFraction;
    return math.min(math.max(targetHeight, minHeight), maxHeight);
  }

  static Future<SessionEndReason> _launchIOS({required String url}) async {
    try {
      _log('ios launch url=$url');
      final sessionFuture = launchUrl(
        Uri.parse(url),
        safariVCOptions: const SafariViewControllerOptions.pageSheet(
          configuration: SheetPresentationControllerConfiguration(
            detents: {SheetPresentationControllerDetent.large},
            largestUndimmedDetentIdentifier:
                SheetPresentationControllerDetent.large,
            prefersScrollingExpandsWhenScrolledToEdge: false,
            prefersGrabberVisible: false,
            prefersEdgeAttachedInCompactHeight: true,
            preferredCornerRadius: 16,
          ),
        ),
      );

      await _applyNativePatchWithRetry();
      await sessionFuture;
      _log('ios sessionFuture completed closeRequested=$_closeRequestedByApp');

      return _closeRequestedByApp
          ? SessionEndReason.closedByApp
          : SessionEndReason.userDismissed;
    } catch (error) {
      debugPrint('[SaveUp] iOS session launch failed: $error');
      _log('ios launch exception=$error');
      return SessionEndReason.launchFailed;
    }
  }

  static Future<void> _applyNativePatchWithRetry() async {
    for (var attempt = 1; attempt <= _retryAttempts; attempt++) {
      await Future<void>.delayed(_retryInterval);

      try {
        final patched =
            await _iosSafariSheetChannel.invokeMethod<bool>(
              'enableUndimmedBackground',
            ) ??
            false;

        if (patched) {
          debugPrint('[SaveUp] Native patch applied on attempt $attempt');
          _log('ios native patch success attempt=$attempt');
          return;
        }
        _log('ios native patch not ready attempt=$attempt');
      } on MissingPluginException {
        debugPrint('[SaveUp] Native patch unavailable on this platform');
        _log('ios native patch unavailable platform');
        return;
      } on PlatformException catch (error) {
        debugPrint('[SaveUp] Native patch error: ${error.message}');
        _log('ios native patch platformException=${error.message}');
      }
    }

    debugPrint('[SaveUp] Native patch fallback: plugin-only sheet config');
    _log('ios native patch fallback after retries');
  }

  static void _log(String message) {
    debugPrint('$_tag $message');
  }

  static AndroidSessionDebugSnapshot getAndroidSessionDebugSnapshot() {
    return AndroidSessionDebugSnapshot(
      browserPackage: _androidBrowserPackage,
      sheetHeight: _androidLaunchedSheetHeight,
      closeCallbacks: _androidCloseCallbacks,
      earlyCloseSuspicious: _androidEarlyCloseSuspicious,
      state: _androidSessionState.name,
    );
  }

  static void _prepareAndroidSessionDebug() {
    _androidCloseCallbacks = 0;
    _androidEarlyCloseSuspicious = false;
    _androidSessionStopwatch = Stopwatch()..start();
    _androidBrowserPackage = null;
    _androidLaunchedSheetHeight = null;
    _setAndroidState(_AndroidSessionState.idle, reason: 'prepare');
  }

  static void _setAndroidState(_AndroidSessionState state, {String? reason}) {
    if (_androidSessionState == state) {
      return;
    }
    _androidSessionState = state;
    _log(
      'android state=${state.name}'
      '${reason == null ? '' : ' reason=$reason'}',
    );
  }
}

enum _AndroidSessionState { idle, launching, active, closing, closed }

class AndroidSessionDebugSnapshot {
  const AndroidSessionDebugSnapshot({
    required this.browserPackage,
    required this.sheetHeight,
    required this.closeCallbacks,
    required this.earlyCloseSuspicious,
    required this.state,
  });

  final String? browserPackage;
  final double? sheetHeight;
  final int closeCallbacks;
  final bool earlyCloseSuspicious;
  final String state;
}

class _AndroidCustomTabsSupport {
  const _AndroidCustomTabsSupport({
    required this.supported,
    this.packageName,
    this.isChrome = false,
    this.reason,
  });

  factory _AndroidCustomTabsSupport.fromMap(Map<String, dynamic>? map) {
    return _AndroidCustomTabsSupport(
      supported: map?['supported'] == true,
      packageName: map?['packageName'] as String?,
      isChrome: map?['isChrome'] == true,
      reason: map?['reason'] as String?,
    );
  }

  final bool supported;
  final String? packageName;
  final bool isChrome;
  final String? reason;
}
