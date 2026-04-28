import 'dart:async';
import 'dart:io';

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

  static bool _closeRequestedByApp = false;
  static Completer<SessionEndReason>? _androidSessionCompleter;
  static bool _androidChannelHandlerRegistered = false;
  static String? _androidBrowserPackage;
  static int _androidCloseCallbacks = 0;
  static String _androidState = 'idle';

  static Future<SessionEndReason> startSession({
    required BuildContext context,
    required String url,
    required double stripHeight,
  }) async {
    _closeRequestedByApp = false;
    _log(
      'startSession platform=${Platform.operatingSystem} '
      'url=$url stripHeight=${stripHeight.toStringAsFixed(1)}',
    );
    await _lockPortrait();

    try {
      if (Platform.isAndroid) {
        return await _launchAndroid(url: url);
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
    _log('endSession requested');

    try {
      if (Platform.isAndroid) {
        _setAndroidState('closing');
        await _androidCustomTabsChannel.invokeMethod<void>(
          'closeCustomTabSession',
        );
        _completeAndroidSession(SessionEndReason.closedByApp);
      } else {
        await closeCustomTabs();
      }
    } finally {
      await unlockOrientation();
      _log('endSession finished');
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

  static Future<SessionEndReason> _launchAndroid({required String url}) async {
    _prepareAndroidSessionDebug();
    _setAndroidState('launching');
    try {
      final support = await _getAndroidCustomTabsSupport();
      _androidBrowserPackage = support.packageName;
      _log(
        'android support supported=${support.supported} '
        'package=${support.packageName} reason=${support.reason}',
      );
      if (!support.supported) {
        return SessionEndReason.unsupportedCustomTabs;
      }

      final sessionClosed = _prepareAndroidSessionCloseWaiter();
      await _androidCustomTabsChannel.invokeMethod<void>(
        'launchCustomTabWithToolbar',
        {'url': url},
      );

      _setAndroidState('active');
      final reason = await sessionClosed;
      _setAndroidState('closed');
      _log('android session closed reason=$reason');
      return reason;
    } on PlatformException catch (error) {
      _log('android launch platformException=${error.message}');
      _setAndroidState('closed');
      _completeAndroidSession(SessionEndReason.launchFailed);
      return SessionEndReason.launchFailed;
    } catch (error) {
      _log('android launch exception=$error');
      _setAndroidState('closed');
      _completeAndroidSession(SessionEndReason.launchFailed);
      return SessionEndReason.launchFailed;
    }
  }

  static Future<_AndroidCustomTabsSupport>
  _getAndroidCustomTabsSupport() async {
    try {
      final support = await _androidCustomTabsChannel
          .invokeMapMethod<String, dynamic>('getCustomTabsSupport');
      return _AndroidCustomTabsSupport.fromMap(support);
    } on MissingPluginException catch (error) {
      _log('android support missing plugin=$error');
      return const _AndroidCustomTabsSupport(
        supported: false,
        reason: 'native channel missing',
      );
    } on PlatformException catch (error) {
      _log('android support platformException=${error.message}');
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
    _androidCustomTabsChannel.setMethodCallHandler((call) async {
      _log('android callback method=${call.method} args=${call.arguments}');
      switch (call.method) {
        case 'customTabsClosed':
          _androidCloseCallbacks++;
          _completeAndroidSession(
            _closeRequestedByApp
                ? SessionEndReason.closedByApp
                : SessionEndReason.userDismissed,
          );
          break;
        case 'secondaryToolbarAction':
          final action = (call.arguments as Map?)?['action'] as String? ?? '';
          if (action == 'save') {
            _completeAndroidSession(SessionEndReason.actionSave);
          } else if (action == 'invest') {
            _completeAndroidSession(SessionEndReason.actionInvest);
          }
          break;
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
    completer.complete(reason);
    _androidSessionCompleter = null;
  }

  static Future<SessionEndReason> _launchIOS({required String url}) async {
    try {
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

      return _closeRequestedByApp
          ? SessionEndReason.closedByApp
          : SessionEndReason.userDismissed;
    } catch (error) {
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
          _log('ios native patch success attempt=$attempt');
          return;
        }
      } on MissingPluginException {
        return;
      } on PlatformException catch (error) {
        _log('ios native patch error=${error.message}');
      }
    }
    _log('ios native patch fallback');
  }

  static AndroidSessionDebugSnapshot getAndroidSessionDebugSnapshot() {
    return AndroidSessionDebugSnapshot(
      browserPackage: _androidBrowserPackage,
      closeCallbacks: _androidCloseCallbacks,
      state: _androidState,
    );
  }

  static void _prepareAndroidSessionDebug() {
    _androidCloseCallbacks = 0;
    _androidBrowserPackage = null;
    _setAndroidState('idle');
  }

  static void _setAndroidState(String value) {
    _androidState = value;
    _log('android state=$value');
  }

  static void _log(String message) {
    debugPrint('$_tag $message');
  }
}

class AndroidSessionDebugSnapshot {
  const AndroidSessionDebugSnapshot({
    required this.browserPackage,
    required this.closeCallbacks,
    required this.state,
  });

  final String? browserPackage;
  final int closeCallbacks;
  final String state;
}

class _AndroidCustomTabsSupport {
  const _AndroidCustomTabsSupport({
    required this.supported,
    this.packageName,
    this.reason,
  });

  factory _AndroidCustomTabsSupport.fromMap(Map<String, dynamic>? map) {
    return _AndroidCustomTabsSupport(
      supported: map?['supported'] == true,
      packageName: map?['packageName'] as String?,
      reason: map?['reason'] as String?,
    );
  }

  final bool supported;
  final String? packageName;
  final String? reason;
}
