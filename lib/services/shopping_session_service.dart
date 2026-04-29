import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/session_end_reason.dart';

class ShoppingSessionService {
  ShoppingSessionService._();

  static const String _tag = '[SaveUp][SessionService]';
  static const String _iosTag = '[SaveUp][iOS][Dart][Session]';
  static const MethodChannel _iosSafariSheetChannel = MethodChannel(
    'com.saveup.app/safari_sheet',
  );
  static const MethodChannel _androidCustomTabsChannel = MethodChannel(
    'com.saveup.app/custom_tabs',
  );
  static const int _retryAttempts = 5;
  static const Duration _retryInterval = Duration(milliseconds: 200);
  static const Duration _iosSessionTimeout = Duration(seconds: 45);

  static bool _closeRequestedByApp = false;
  static Completer<SessionEndReason>? _androidSessionCompleter;
  static bool _androidChannelHandlerRegistered = false;
  static String? _androidBrowserPackage;
  static int _androidCloseCallbacks = 0;
  static String _androidState = 'idle';
  static bool _iosChannelHandlerRegistered = false;
  static Completer<SessionEndReason>? _iosSessionCompleter;
  static String? _iosActiveSessionId;
  static String _iosState = 'idle';
  static int _iosSessionCounter = 0;
  static int _iosPatchAttempts = 0;
  static bool _iosPatchSuccess = false;
  static int _iosDuplicateCallbacks = 0;
  static DateTime? _iosSessionStartedAt;
  static int _iosEventCounter = 0;
  static String? _iosLastErrorCode;
  static String? _iosLastErrorMessage;
  static String? _iosLastCloseSource;

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
        final sessionId = _iosActiveSessionId;
        _setIosState('closing');
        if (sessionId != null) {
          await _requestIosClose(
            sessionId: sessionId,
            trigger: 'end_session',
            source: 'dart_endSession',
          );
        }
        _completeIosSession(SessionEndReason.closedByApp, source: 'endSession');
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
    _registerIosChannelHandler();
    _prepareIosSessionDebug();
    final sessionId = _nextIosSessionId();
    _iosActiveSessionId = sessionId;
    _iosSessionStartedAt = DateTime.now();
    _setIosState('launching');
    _iosLog(
      'event=${_nextIosEvent()} sessionId=$sessionId action=launch-request',
    );
    try {
      final response = await _iosSafariSheetChannel
          .invokeMapMethod<String, dynamic>('startSafariSession', {
            'url': url,
            'sessionId': sessionId,
          });

      final started = response?['started'] == true;
      if (!started) {
        _iosLastErrorCode = _safeString(response?['code']) ?? 'IOS_A1';
        _iosLastErrorMessage =
            _safeString(response?['error']) ??
            'Failed to present Safari sheet.';
        _iosLog(
          'event=${_nextIosEvent()} sessionId=$sessionId '
          'state=$_iosState code=$_iosLastErrorCode '
          'message=$_iosLastErrorMessage',
        );
        _setIosState('closed');
        _iosActiveSessionId = null;
        return SessionEndReason.launchFailed;
      }

      final closeFuture = _prepareIosSessionCloseWaiter(sessionId: sessionId);
      _setIosState('presenting');
      await _applyIosPatchWithRetry(sessionId: sessionId);
      _setIosState('active');
      final reason = await closeFuture;
      _setIosState('closed');
      _iosLogSessionSummary(reason);
      _iosActiveSessionId = null;
      return reason;
    } on MissingPluginException catch (error) {
      _iosLastErrorCode = 'IOS_A2';
      _iosLastErrorMessage = error.toString();
      _iosLog(
        'event=${_nextIosEvent()} sessionId=$sessionId '
        'state=$_iosState code=$_iosLastErrorCode message=$_iosLastErrorMessage',
      );
      _setIosState('closed');
      _iosActiveSessionId = null;
      return SessionEndReason.launchFailed;
    } on PlatformException catch (error) {
      _iosLastErrorCode = 'IOS_A3';
      _iosLastErrorMessage = error.message ?? error.toString();
      _iosLog(
        'event=${_nextIosEvent()} sessionId=$sessionId '
        'state=$_iosState code=$_iosLastErrorCode message=$_iosLastErrorMessage',
      );
      _setIosState('closed');
      _iosActiveSessionId = null;
      return SessionEndReason.launchFailed;
    } catch (error) {
      _iosLastErrorCode = 'IOS_A4';
      _iosLastErrorMessage = error.toString();
      _iosLog(
        'event=${_nextIosEvent()} sessionId=$sessionId '
        'state=$_iosState code=$_iosLastErrorCode message=$_iosLastErrorMessage',
      );
      _setIosState('closed');
      _iosActiveSessionId = null;
      return SessionEndReason.launchFailed;
    }
  }

  static Future<void> _applyIosPatchWithRetry({
    required String sessionId,
  }) async {
    for (var attempt = 1; attempt <= _retryAttempts; attempt++) {
      await Future<void>.delayed(_retryInterval);
      try {
        final patchResult = await _iosSafariSheetChannel
            .invokeMapMethod<String, dynamic>('patchSheetIfPresented', {
              'sessionId': sessionId,
              'attempt': attempt,
            });
        final patched = patchResult?['patched'] == true;
        _iosPatchAttempts = attempt;
        if (patched) {
          _iosPatchSuccess = true;
          _iosLog(
            'event=${_nextIosEvent()} sessionId=$sessionId '
            'state=$_iosState action=patch-success attempt=$attempt',
          );
          return;
        }
      } on MissingPluginException {
        _iosLastErrorCode = 'IOS_B2';
        _iosLastErrorMessage = 'patch method channel missing';
        return;
      } on PlatformException catch (error) {
        _iosLastErrorCode = 'IOS_B3';
        _iosLastErrorMessage = error.message ?? error.toString();
        _iosLog(
          'event=${_nextIosEvent()} sessionId=$sessionId '
          'state=$_iosState code=$_iosLastErrorCode '
          'message=$_iosLastErrorMessage',
        );
      }
    }
    _iosLastErrorCode = 'IOS_B1';
    _iosLastErrorMessage = 'Patch attempts exhausted';
    _iosLog(
      'event=${_nextIosEvent()} sessionId=$sessionId state=$_iosState '
      'code=$_iosLastErrorCode message=$_iosLastErrorMessage',
    );
  }

  static Future<SessionEndReason> _prepareIosSessionCloseWaiter({
    required String sessionId,
  }) async {
    final completer = Completer<SessionEndReason>();
    _iosSessionCompleter = completer;

    return completer.future.timeout(
      _iosSessionTimeout,
      onTimeout: () {
        _iosLastErrorCode = 'IOS_C1';
        _iosLastErrorMessage = 'Close callback timeout';
        _iosLog(
          'event=${_nextIosEvent()} sessionId=$sessionId state=$_iosState '
          'code=$_iosLastErrorCode message=$_iosLastErrorMessage',
        );
        unawaited(
          _requestIosClose(
            sessionId: sessionId,
            trigger: 'watchdog_timeout',
            source: 'dart_timeout_guard',
          ),
        );
        _completeIosSession(SessionEndReason.launchFailed, source: 'watchdog');
        return SessionEndReason.launchFailed;
      },
    );
  }

  static Future<void> _requestIosClose({
    required String sessionId,
    required String trigger,
    required String source,
  }) async {
    try {
      await _iosSafariSheetChannel.invokeMapMethod<String, dynamic>(
        'closeSafariSession',
        {'sessionId': sessionId, 'trigger': trigger},
      );
      _iosLog(
        'event=${_nextIosEvent()} sessionId=$sessionId state=$_iosState '
        'action=close-request trigger=$trigger source=$source',
      );
    } on Object catch (error) {
      _iosLastErrorCode = 'IOS_C2';
      _iosLastErrorMessage = 'close request failed: $error';
      _iosLog(
        'event=${_nextIosEvent()} sessionId=$sessionId state=$_iosState '
        'code=$_iosLastErrorCode message=$_iosLastErrorMessage',
      );
    }
  }

  static void _registerIosChannelHandler() {
    if (_iosChannelHandlerRegistered) {
      return;
    }
    _iosChannelHandlerRegistered = true;
    _iosSafariSheetChannel.setMethodCallHandler((call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
      final callbackSessionId = _safeString(args['sessionId']);
      final activeSessionId = _iosActiveSessionId;

      if (callbackSessionId == null) {
        _iosLog(
          'event=${_nextIosEvent()} sessionId=missing state=$_iosState '
          'action=ignore-missing-session-id method=${call.method}',
        );
        return;
      }

      if (activeSessionId == null || callbackSessionId != activeSessionId) {
        _iosDuplicateCallbacks++;
        _iosLog(
          'event=${_nextIosEvent()} sessionId=$callbackSessionId state=$_iosState '
          'action=ignore-stale method=${call.method} activeSessionId=$activeSessionId',
        );
        return;
      }

      _iosLog(
        'event=${_nextIosEvent()} sessionId=$callbackSessionId '
        'state=$_iosState action=callback method=${call.method} args=$args',
      );

      switch (call.method) {
        case 'safariSessionPresented':
          _setIosState('active');
          break;
        case 'safariSessionPatched':
          _iosPatchSuccess = args['undimmedApplied'] == true;
          _iosPatchAttempts = (args['attempt'] as int?) ?? _iosPatchAttempts;
          break;
        case 'safariSessionClosed':
          final reason = _safeString(args['reason']) ?? 'userDismissed';
          final source = _safeString(args['source']) ?? 'native';
          _iosLastCloseSource = source;
          if (reason == 'closedByApp') {
            _completeIosSession(
              SessionEndReason.closedByApp,
              source: 'native_closedByApp:$source',
            );
          } else {
            _completeIosSession(
              SessionEndReason.userDismissed,
              source: 'native_userDismissed:$source',
            );
          }
          break;
        case 'safariSessionError':
          final code = _safeString(args['code']) ?? 'IOS_A9';
          final message = _safeString(args['message']) ?? 'Unknown iOS error';
          _iosLastErrorCode = code;
          _iosLastErrorMessage = message;
          _completeIosSession(
            SessionEndReason.launchFailed,
            source: 'error:$code',
          );
          break;
      }
    });
  }

  static void _completeIosSession(
    SessionEndReason reason, {
    required String source,
  }) {
    final completer = _iosSessionCompleter;
    if (completer == null || completer.isCompleted) {
      _iosDuplicateCallbacks++;
      _iosLog(
        'event=${_nextIosEvent()} sessionId=$_iosActiveSessionId '
        'state=$_iosState action=ignore-duplicate-complete reason=$reason source=$source',
      );
      return;
    }
    _iosLog(
      'event=${_nextIosEvent()} sessionId=$_iosActiveSessionId '
      'state=$_iosState action=complete reason=$reason source=$source',
    );
    completer.complete(reason);
    _iosSessionCompleter = null;
  }

  static void _prepareIosSessionDebug() {
    _iosPatchAttempts = 0;
    _iosPatchSuccess = false;
    _iosDuplicateCallbacks = 0;
    _iosLastErrorCode = null;
    _iosLastErrorMessage = null;
    _iosLastCloseSource = null;
    _setIosState('idle');
  }

  static String _nextIosSessionId() {
    _iosSessionCounter += 1;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return 'ios-$nowMs-$_iosSessionCounter';
  }

  static String _nextIosEvent() {
    _iosEventCounter += 1;
    return 'e$_iosEventCounter';
  }

  static void _setIosState(String value) {
    _iosState = value;
    _iosLog(
      'event=${_nextIosEvent()} sessionId=$_iosActiveSessionId '
      'state=$_iosState action=state-transition',
    );
  }

  static void _iosLogSessionSummary(SessionEndReason reason) {
    final durationMs = _iosSessionStartedAt == null
        ? -1
        : DateTime.now().difference(_iosSessionStartedAt!).inMilliseconds;
    _iosLog(
      'event=${_nextIosEvent()} sessionId=$_iosActiveSessionId '
      'state=$_iosState action=session-summary '
      'reason=$reason durationMs=$durationMs '
      'patchAttempts=$_iosPatchAttempts patchSuccess=$_iosPatchSuccess '
      'duplicates=$_iosDuplicateCallbacks closeSource=$_iosLastCloseSource '
      'errorCode=$_iosLastErrorCode errorMessage=$_iosLastErrorMessage',
    );
  }

  static String? _safeString(Object? value) {
    if (value == null) {
      return null;
    }
    return value.toString();
  }

  static void _iosLog(String message) {
    final timestampMs = DateTime.now().millisecondsSinceEpoch;
    final thread = Platform.isIOS ? 'ui-thread-assumed' : 'unknown';
    debugPrint('$_iosTag timestampMs=$timestampMs thread=$thread $message');
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
