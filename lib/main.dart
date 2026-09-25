import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:workmanager/workmanager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
//plattformspezifische Cookie-Steuerung:
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Host der Moodle-Plattform. Auto-Login wird ausschließlich hier ausgeführt.
const String kMoodleHost = 'moodle.fes-pforzheim.de';

/// Moodle-Nachrichtenseite (Rückfall / "In Moodle öffnen")
const String kMessagesUrl =
    'https://moodle.fes-pforzheim.de/moodle/message/index.php';

/// Wartezeit, bevor der Lade-Bildschirm nach einem Auto-Login verschwindet,
/// nachdem Moodle "Seite fertig" gemeldet hat (verhindert Aufblitzen der Login-Seite).
const Duration kOverlayHideDelay = Duration(milliseconds: 1000);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AuthService.instance.load();
  await NotificationService.init();
  if (Platform.isAndroid) {
    // Läuft nur unter Android zuverlässig (siehe BackgroundSync-Hinweise unten).
    try {
      await Workmanager().initialize(callbackDispatcher);
      if (AuthService.instance.credentials.value != null) {
        await BackgroundSync.enable();
      }
    } catch (e) {
      debugPrint('Workmanager konnte nicht gestartet werden: $e');
    }
  }
  runApp(const MyApp());
}

// ==========================================
// 0c. HINTERGRUND-BENACHRICHTIGUNGEN (nur Android)
// ==========================================

const String _kBackgroundTaskUid = 'fes_app_unread_check';
const String _kBackgroundTaskName = 'unread_check';
const String _kLastNotifiedKey = 'moodle_last_notified_unread';

/// Muss eine globale, mit @pragma('vm:entry-point') markierte Funktion sein:
/// Workmanager startet sie in einem eigenen Hintergrund-Isolate.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    debugPrint('[BackgroundSync] Job gestartet ($task)');
    await BackgroundSync.performCheck(logPrefix: '[BackgroundSync]');
    return true;
  });
}

/// Ergebnis eines Prüflaufs, für die Diagnose-Anzeige in der App.
class SyncCheckResult {
  final bool hadCredentials;
  final int? unreadCount;
  final int? lastNotified;
  final bool notified;
  final String? error;
  const SyncCheckResult({
    required this.hadCredentials,
    required this.unreadCount,
    required this.lastNotified,
    required this.notified,
    required this.error,
  });
}

/// An- und Abmelden der periodischen Hintergrundprüfung.
class BackgroundSync {
  BackgroundSync._();

  /// Die eigentliche Prüf-Logik: exakt das, was der echte Hintergrundjob
  /// alle 15 Minuten (bzw. seltener, je nach Android-Einstufung) ausführt.
  /// Wird auch vom Diagnose-Knopf im Dashboard genutzt, damit man sie sofort
  /// testen kann, ohne auf den Android-Scheduler zu warten.
  static Future<SyncCheckResult> performCheck({String logPrefix = '[Sync]'}) async {
    void log(String m) => debugPrint('$logPrefix $m');
    try {
      await NotificationService.init();
      await AuthService.instance.load();
      if (AuthService.instance.credentials.value == null) {
        log('Keine gespeicherten Zugangsdaten gefunden.');
        return const SyncCheckResult(
          hadCredentials: false,
          unreadCount: null,
          lastNotified: null,
          notified: false,
          error: null,
        );
      }

      // Statt nur die Anzahl ungelesener UNTERHALTUNGEN zu vergleichen (die
      // bei einer weiteren Nachricht in derselben, schon ungelesenen
      // Unterhaltung gleich bleibt), merken wir uns die höchste Nachrichten-ID
      // einer fremden Nachricht. Jede neue Nachricht hat eine höhere ID, damit
      // erkennen wir wirklich JEDE neue Nachricht, nicht nur die erste pro
      // Unterhaltung.
      final result = await MoodleApi.fetchConversations();
      var unreadConversations = 0;
      var maxForeignMessageId = 0;
      for (final c in result.items) {
        if (c.unread > 0) unreadConversations++;
        final last = c.last;
        if (last != null &&
            last.fromUserId != result.myUserId &&
            last.id > maxForeignMessageId) {
          maxForeignMessageId = last.id;
        }
      }

      const storage = FlutterSecureStorage();
      final lastStr = await storage.read(key: _kLastNotifiedKey);
      final lastSeenMessageId = int.tryParse(lastStr ?? '') ?? 0;
      log(
        'Neueste fremde Nachricht-ID: $maxForeignMessageId, zuletzt gemeldet: '
        '$lastSeenMessageId, ungelesene Unterhaltungen: $unreadConversations',
      );

      var notified = false;
      if (maxForeignMessageId > lastSeenMessageId) {
        log('Zeige Benachrichtigung für $unreadConversations ungelesene Unterhaltung(en).');
        await NotificationService.showNewMessages(
          unreadConversations > 0 ? unreadConversations : 1,
        );
        notified = true;
      } else {
        log('Keine neue Nachricht seit dem letzten Mal.');
      }
      await storage.write(
        key: _kLastNotifiedKey,
        value: maxForeignMessageId.toString(),
      );
      log('Prüfung abgeschlossen.');
      return SyncCheckResult(
        hadCredentials: true,
        unreadCount: unreadConversations,
        lastNotified: lastSeenMessageId,
        notified: notified,
        error: null,
      );
    } catch (e, st) {
      log('Fehler: $e\n$st');
      return SyncCheckResult(
        hadCredentials: true,
        unreadCount: null,
        lastNotified: null,
        notified: false,
        error: e.toString(),
      );
    }
  }

  /// Setzt den "zuletzt gemeldet"-Stand zurück, damit ein erneuter Test ohne
  /// Vorbedingungen (Nachricht muss ungelesen UND höher als beim letzten
  /// Test sein) sauber durchläuft.
  static Future<void> resetLastNotified() async {
    try {
      await const FlutterSecureStorage().delete(key: _kLastNotifiedKey);
    } catch (_) {}
  }

  static Future<void> enable() async {
    if (!Platform.isAndroid) return;
    try {
      await Workmanager().registerPeriodicTask(
        _kBackgroundTaskUid,
        _kBackgroundTaskName,
        // Android erzwingt ohnehin ein Minimum von 15 Minuten.
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (e) {
      debugPrint('[BackgroundSync] Konnte nicht aktiviert werden: $e');
    }
  }

  static Future<void> disable() async {
    if (!Platform.isAndroid) return;
    try {
      await Workmanager().cancelByUniqueName(_kBackgroundTaskUid);
    } catch (e) {
      debugPrint('[BackgroundSync] Konnte nicht deaktiviert werden: $e');
    }
    try {
      await const FlutterSecureStorage().delete(key: _kLastNotifiedKey);
    } catch (_) {}
  }
}

/// Anzeige lokaler Benachrichtigungen (im Vorder- und im Hintergrund-Isolate
/// gleichermaßen nutzbar).
class NotificationService {
  NotificationService._();
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'moodle_messages',
    'Moodle-Nachrichten',
    description: 'Benachrichtigung bei neuen ungelesenen Moodle-Nachrichten',
    importance: Importance.defaultImportance,
  );

  static Future<void> init() async {
    if (_initialized) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: androidInit),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);
    _initialized = true;
  }

  /// Fragt unter Android 13+ die Benachrichtigungs-Berechtigung ab. Vorher
  /// erscheinen sonst keine Benachrichtigungen, ohne dass die App das merkt.
  static Future<void> requestPermission() async {
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('Benachrichtigungs-Berechtigung nicht abfragbar: $e');
    }
  }

  static Future<void> showNewMessages(int count) async {
    await init();
    final text = count == 1
        ? 'Du hast eine neue ungelesene Nachricht.'
        : 'Du hast $count neue ungelesene Nachrichten.';
    await _plugin.show(
      1001,
      'Moodle-Nachrichten',
      text,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
      ),
    );
  }
}

// ==========================================
// 0. ANMELDUNG: Zugangsdaten und Moodle-Token sicher speichern
// ==========================================
class Credentials {
  final String username;
  final String password;
  const Credentials(this.username, this.password);
}

/// Token der Moodle-Web-Services (wie in der offiziellen Moodle-App).
class MoodleTokens {
  final String token;
  final String privateToken;
  final int userId;
  const MoodleTokens({
    required this.token,
    required this.privateToken,
    required this.userId,
  });
}

class MoodleApiException implements Exception {
  final String message;
  final String? code;
  const MoodleApiException(this.message, {this.code});

  @override
  String toString() => 'MoodleApiException($code): $message';
}

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  static const _storage = FlutterSecureStorage();
  static const _kUser = 'moodle_username';
  static const _kPass = 'moodle_password';
  static const _kToken = 'moodle_token';
  static const _kPrivateToken = 'moodle_privatetoken';
  static const _kUserId = 'moodle_userid';

  /// null = (noch) nicht angemeldet
  final ValueNotifier<Credentials?> credentials =
      ValueNotifier<Credentials?>(null);

  /// Web-Service-Token. Fehlt es (z. B. nach einem App-Update), wird es bei
  /// Bedarf still mit den gespeicherten Zugangsdaten neu geholt.
  MoodleTokens? tokens;

  Future<void> load() async {
    try {
      final user = await _storage.read(key: _kUser);
      final pass = await _storage.read(key: _kPass);
      final token = await _storage.read(key: _kToken);
      final priv = await _storage.read(key: _kPrivateToken);
      final uid = int.tryParse(await _storage.read(key: _kUserId) ?? '');
      tokens = (token != null && priv != null && uid != null)
          ? MoodleTokens(token: token, privateToken: priv, userId: uid)
          : null;
      credentials.value =
          (user != null && pass != null) ? Credentials(user, pass) : null;
    } catch (e) {
      // z. B. Keystore-Problem nach Backup-Wiederherstellung: sauber zurücksetzen
      debugPrint('Secure Storage nicht lesbar: $e');
      try {
        await _storage.deleteAll();
      } catch (_) {}
      tokens = null;
      credentials.value = null;
    }
  }

  Future<void> save(
    String username,
    String password,
    MoodleTokens newTokens,
  ) async {
    await _storage.write(key: _kUser, value: username);
    await _storage.write(key: _kPass, value: password);
    await _writeTokens(newTokens);
    credentials.value = Credentials(username, password);
  }

  Future<void> _writeTokens(MoodleTokens t) async {
    tokens = t;
    await _storage.write(key: _kToken, value: t.token);
    await _storage.write(key: _kPrivateToken, value: t.privateToken);
    await _storage.write(key: _kUserId, value: t.userId.toString());
  }

  /// Holt mit den gespeicherten Zugangsdaten ein neues Token.
  Future<bool> refreshTokens() async {
    final c = credentials.value;
    if (c == null) return false;
    try {
      await _writeTokens(await MoodleApi.requestTokens(c.username, c.password));
      return true;
    } catch (e) {
      debugPrint('Token-Erneuerung fehlgeschlagen: $e');
      return false;
    }
  }

  Future<void> clear() async {
    tokens = null;
    try {
      for (final key in [_kUser, _kPass, _kToken, _kPrivateToken, _kUserId]) {
        await _storage.delete(key: key);
      }
    } catch (_) {}
    credentials.value = null;
  }
}

/// Zugriff auf die Moodle-Web-Services (Token, Auto-Login-Schlüssel,
/// ungelesene Nachrichten).
class MoodleApi {
  static const String _base = 'https://$kMoodleHost/moodle';
  static const Duration _timeout = Duration(seconds: 15);

  static dynamic _decode(http.Response res) =>
      jsonDecode(utf8.decode(res.bodyBytes));

  static String _messageOf(dynamic json, String fallback) {
    if (json is Map) {
      final m = json['error'] ?? json['message'];
      if (m is String && m.isNotEmpty) return m;
    }
    return fallback;
  }

  static String? _codeOf(dynamic json) =>
      json is Map ? json['errorcode']?.toString() : null;

  /// Anmeldung über login/token.php. Prüft dabei gleichzeitig die
  /// Zugangsdaten; bei falschen Daten wird eine MoodleApiException mit der
  /// (deutschen) Fehlermeldung von Moodle geworfen.
  static Future<MoodleTokens> requestTokens(
    String username,
    String password,
  ) async {
    final res = await http.post(
      Uri.parse('$_base/login/token.php'),
      body: {
        'username': username,
        'password': password,
        'service': 'moodle_mobile_app',
      },
    ).timeout(_timeout);
    final json = _decode(res);
    if (json is Map && json['token'] is String) {
      final token = json['token'] as String;
      final userId = await _fetchUserId(token);
      return MoodleTokens(
        token: token,
        privateToken: (json['privatetoken'] as String?) ?? '',
        userId: userId,
      );
    }
    throw MoodleApiException(
      _messageOf(json, 'Anmeldung bei Moodle fehlgeschlagen.'),
      code: _codeOf(json),
    );
  }

  static Future<int> _fetchUserId(String token) async {
    final json = await _call(token, 'core_webservice_get_site_info');
    final id = json is Map ? json['userid'] : null;
    if (id is int) return id;
    throw const MoodleApiException('Benutzer-ID konnte nicht ermittelt werden.');
  }

  static Future<dynamic> _call(
    String token,
    String function, {
    Map<String, String> params = const {},
    bool mobileUserAgent = false,
  }) async {
    final res = await http.post(
      Uri.parse('$_base/webservice/rest/server.php?moodlewsrestformat=json'),
      // Moodle erlaubt Auto-Login-Schlüssel nur für Anfragen der Mobile-App.
      headers: mobileUserAgent ? {'User-Agent': 'MoodleMobile'} : null,
      body: {'wstoken': token, 'wsfunction': function, ...params},
    ).timeout(_timeout);
    final json = _decode(res);
    if (json is Map &&
        (json.containsKey('exception') || json.containsKey('errorcode'))) {
      throw MoodleApiException(
        _messageOf(json, 'Moodle-Fehler.'),
        code: _codeOf(json),
      );
    }
    return json;
  }

  /// Führt [action] mit dem aktuellen Token aus. Ist das Token ungültig
  /// (abgelaufen), wird einmal still ein neues geholt und es erneut versucht.
  static Future<T> _withTokens<T>(
    Future<T> Function(MoodleTokens t) action,
  ) async {
    final auth = AuthService.instance;
    if (auth.tokens == null && !await auth.refreshTokens()) {
      throw const MoodleApiException(
        'Kein Moodle-Token verfügbar.',
        code: 'notoken',
      );
    }
    try {
      return await action(auth.tokens!);
    } on MoodleApiException catch (e) {
      if (e.code == 'invalidtoken' && await auth.refreshTokens()) {
        return action(auth.tokens!);
      }
      rethrow;
    }
  }

  /// Baut eine Auto-Login-URL, die direkt angemeldet auf [target] öffnet.
  /// Gibt null zurück, wenn kein Schlüssel verfügbar ist (z. B. Mindestabstand
  /// zwischen zwei Schlüsseln, Admin-Konto, keine Verbindung).
  static Future<String?> buildAutologinUrl(String target) async {
    try {
      return await _withTokens<String?>((t) async {
        final json = await _call(
          t.token,
          'tool_mobile_get_autologin_key',
          params: {'privatetoken': t.privateToken},
          mobileUserAgent: true,
        );
        if (json is! Map) return null;
        final key = json['key'];
        final base = json['autologinurl'];
        if (key is! String || base is! String) return null;
        final uri = Uri.parse(base);
        return uri.replace(queryParameters: {
          ...uri.queryParameters,
          'userid': t.userId.toString(),
          'key': key,
          'urltogo': target,
        }).toString();
      });
    } catch (e) {
      debugPrint('Kein Auto-Login-Schlüssel: $e');
      return null;
    }
  }

  /// Anzahl der Konversationen mit ungelesenen Nachrichten (null bei Fehler).
  static Future<int?> fetchUnreadCount() async {
    try {
      return await _withTokens<int?>((t) async {
        final json = await _call(
          t.token,
          'core_message_get_unread_conversations_count',
          params: {'useridto': t.userId.toString()},
        );
        return json is num ? json.toInt() : null;
      });
    } catch (e) {
      debugPrint('Ungelesene Nachrichten nicht abrufbar: $e');
      return null;
    }
  }

  // ---------- Nachrichten (native Ansicht) ----------

  static ChatMessage? _parseMessage(dynamic m) {
    if (m is! Map) return null;
    final id = m['id'];
    final from = m['useridfrom'];
    final time = m['timecreated'];
    if (id is! int || from is! int || time is! int) return null;
    final text = m['text'];
    return ChatMessage(
      id: id,
      fromUserId: from,
      text: htmlToText(text is String ? text : ''),
      time: time,
    );
  }

  static Conversation? _parseConversation(dynamic j, int myUserId) {
    if (j is! Map) return null;
    final id = j['id'];
    if (id is! int) return null;

    var name = j['name'] is String ? (j['name'] as String).trim() : '';
    final members = j['members'];
    if (name.isEmpty && members is List) {
      for (final m in members) {
        if (m is Map && m['id'] != myUserId && m['fullname'] is String) {
          name = m['fullname'] as String;
          break;
        }
      }
    }
    if (name.isEmpty) name = 'Unterhaltung';

    ChatMessage? last;
    final msgs = j['messages'];
    if (msgs is List) {
      for (final m in msgs) {
        final parsed = _parseMessage(m);
        if (parsed != null && (last == null || parsed.time >= last.time)) {
          last = parsed;
        }
      }
    }

    var unread = 0;
    final unreadCount = j['unreadcount'];
    if (unreadCount is int) {
      unread = unreadCount;
    } else if (j['isread'] == false) {
      unread = 1;
    }

    return Conversation(
      id: id,
      name: name,
      type: j['type'] is int ? j['type'] as int : 1,
      unread: unread,
      last: last,
      canDeleteForAll: j['candeletemessagesforallusers'] == true,
    );
  }

  /// Liste der Unterhaltungen (neueste zuerst).
  static Future<ConversationsResult> fetchConversations() {
    return _withTokens<ConversationsResult>((t) async {
      final json = await _call(
        t.token,
        'core_message_get_conversations',
        params: {
          'userid': t.userId.toString(),
          'limitfrom': '0',
          'limitnum': '50',
        },
      );
      final raw = json is Map ? json['conversations'] : null;
      final items = <Conversation>[];
      if (raw is List) {
        for (final j in raw) {
          final c = _parseConversation(j, t.userId);
          if (c != null) items.add(c);
        }
      }
      items.sort((a, b) => (b.last?.time ?? 0).compareTo(a.last?.time ?? 0));
      return ConversationsResult(myUserId: t.userId, items: items);
    });
  }

  /// Die neuesten Nachrichten einer Unterhaltung (älteste zuerst).
  static Future<MessagesResult> fetchMessages(int conversationId) {
    return _withTokens<MessagesResult>((t) async {
      final json = await _call(
        t.token,
        'core_message_get_conversation_messages',
        params: {
          'currentuserid': t.userId.toString(),
          'convid': conversationId.toString(),
          'limitfrom': '0',
          'limitnum': '60',
          'newest': '1',
        },
      );
      final messages = <ChatMessage>[];
      final names = <int, String>{};
      if (json is Map) {
        final rawMessages = json['messages'];
        if (rawMessages is List) {
          for (final m in rawMessages) {
            final parsed = _parseMessage(m);
            if (parsed != null) messages.add(parsed);
          }
        }
        final members = json['members'];
        if (members is List) {
          for (final m in members) {
            if (m is Map && m['id'] is int && m['fullname'] is String) {
              names[m['id'] as int] = m['fullname'] as String;
            }
          }
        }
      }
      messages.sort((a, b) {
        final c = a.time.compareTo(b.time);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
      return MessagesResult(
        myUserId: t.userId,
        messages: messages,
        names: names,
      );
    });
  }

  static Future<void> sendMessage(int conversationId, String text) {
    return _withTokens<void>((t) async {
      await _call(
        t.token,
        'core_message_send_messages_to_conversation',
        params: {
          'conversationid': conversationId.toString(),
          'messages[0][text]': text,
        },
      );
    });
  }

  /// Markiert alle Nachrichten der Unterhaltung als gelesen (Fehler egal).
  static Future<void> markConversationRead(int conversationId) async {
    try {
      await _withTokens<void>((t) async {
        await _call(
          t.token,
          'core_message_mark_all_conversation_messages_as_read',
          params: {
            'userid': t.userId.toString(),
            'conversationid': conversationId.toString(),
          },
        );
      });
    } catch (e) {
      debugPrint('Als gelesen markieren fehlgeschlagen: $e');
    }
  }

  // ---------- Nachrichten: Suche, neue Unterhaltung, Löschen ----------

  static MoodleUser? _parseUser(
    dynamic u, {
    bool contact = false,
    int myUserId = 0,
  }) {
    if (u is! Map) return null;
    final id = u['id'];
    final name = u['fullname'];
    if (id is! int || name is! String || id == myUserId) return null;
    final requests = u['contactrequests'];
    return MoodleUser(
      id: id,
      name: name,
      isContact: contact || u['iscontact'] == true,
      canMessage: u['canmessage'] != false,
      requiresContact: u['requirescontact'] == true,
      requestPending: requests is List && requests.isNotEmpty,
    );
  }

  /// Personensuche (Kontakte zuerst). Was Moodle hier liefert, hängt von den
  /// Nachrichten-Einstellungen der Website ab.
  static Future<List<MoodleUser>> searchUsers(String query) {
    return _withTokens<List<MoodleUser>>((t) async {
      final json = await _call(
        t.token,
        'core_message_message_search_users',
        params: {
          'userid': t.userId.toString(),
          'search': query,
          'limitfrom': '0',
          'limitnum': '30',
        },
      );
      final users = <MoodleUser>[];
      if (json is Map) {
        for (final key in ['contacts', 'noncontacts']) {
          final raw = json[key];
          if (raw is List) {
            for (final u in raw) {
              final parsed = _parseUser(
                u,
                contact: key == 'contacts',
                myUserId: t.userId,
              );
              if (parsed != null) users.add(parsed);
            }
          }
        }
      }
      return users;
    });
  }

  /// ID einer bestehenden Einzel-Unterhaltung mit [otherUserId] (sonst null).
  static Future<int?> findConversationWith(int otherUserId) async {
    try {
      return await _withTokens<int?>((t) async {
        final json = await _call(
          t.token,
          'core_message_get_conversation_between_users',
          params: {
            'userid': t.userId.toString(),
            'otheruserid': otherUserId.toString(),
          },
        );
        final id = json is Map ? json['id'] : null;
        return id is int ? id : null;
      });
    } on MoodleApiException catch (e) {
      // Moodle meldet hier einen Fehler, wenn es noch keine Unterhaltung gibt
      debugPrint('Keine bestehende Unterhaltung: $e');
      return null;
    }
  }

  /// Sendet die erste Nachricht an eine Person und legt dabei die
  /// Unterhaltung an. Gibt die ID der Unterhaltung zurück.
  static Future<int> sendInstantMessage(int toUserId, String text) async {
    final result = await _withTokens<Map>((t) async {
      final json = await _call(
        t.token,
        'core_message_send_instant_messages',
        params: {
          'messages[0][touserid]': toUserId.toString(),
          'messages[0][text]': text,
        },
      );
      if (json is List && json.isNotEmpty && json.first is Map) {
        return json.first as Map;
      }
      throw const MoodleApiException('Nachricht konnte nicht gesendet werden.');
    });
    final error = result['errormessage'];
    if (error is String && error.isNotEmpty) throw MoodleApiException(error);
    final convId = result['conversationid'];
    if (convId is int) return convId;
    final found = await findConversationWith(toUserId);
    if (found != null) return found;
    throw const MoodleApiException('Nachricht konnte nicht gesendet werden.');
  }

  static Future<void> deleteMessage(int messageId, {bool forAll = false}) {
    return _withTokens<void>((t) async {
      final json = await _call(
        t.token,
        forAll
            ? 'core_message_delete_message_for_all_users'
            : 'core_message_delete_message',
        params: {
          'messageid': messageId.toString(),
          'userid': t.userId.toString(),
        },
      );
      if (json is Map && json['status'] == false) {
        throw const MoodleApiException(
          'Die Nachricht konnte nicht gelöscht werden.',
        );
      }
    });
  }

  /// Löscht die Unterhaltung nur für den angemeldeten Nutzer.
  static Future<void> deleteConversation(int conversationId) {
    return _withTokens<void>((t) async {
      await _call(
        t.token,
        'core_message_delete_conversations_by_id',
        params: {
          'userid': t.userId.toString(),
          'conversationids[0]': conversationId.toString(),
        },
      );
    });
  }

  // ---------- Kontaktanfragen ----------

  static Future<void> createContactRequest(int userId) {
    return _withTokens<void>((t) async {
      final json = await _call(
        t.token,
        'core_message_create_contact_request',
        params: {
          'userid': t.userId.toString(),
          'requesteduserid': userId.toString(),
        },
      );
      final warnings = json is Map ? json['warnings'] : null;
      if (warnings is List && warnings.isNotEmpty) {
        final w = warnings.first;
        throw MoodleApiException(
          w is Map && w['message'] is String
              ? w['message'] as String
              : 'Kontaktanfrage nicht möglich.',
        );
      }
    });
  }

  /// Erhaltene Kontaktanfragen (die anfragenden Personen).
  static Future<List<MoodleUser>> fetchContactRequests() {
    return _withTokens<List<MoodleUser>>((t) async {
      final json = await _call(
        t.token,
        'core_message_get_contact_requests',
        params: {
          'userid': t.userId.toString(),
          'limitfrom': '0',
          'limitnum': '50',
        },
      );
      final users = <MoodleUser>[];
      if (json is List) {
        for (final u in json) {
          if (u is! Map) continue;
          // Benutzer-Objekt (id, fullname) oder Anfrage-Objekt (userid)
          final hasName = u['fullname'] is String;
          final id = hasName ? u['id'] : (u['userid'] ?? u['id']);
          if (id is! int) continue;
          users.add(
            MoodleUser(
              id: id,
              name: hasName ? u['fullname'] as String : 'Benutzer $id',
            ),
          );
        }
      }
      return users;
    });
  }

  static Future<int?> fetchContactRequestCount() async {
    try {
      return await _withTokens<int?>((t) async {
        final json = await _call(
          t.token,
          'core_message_get_received_contact_requests_count',
          params: {'userid': t.userId.toString()},
        );
        return json is num ? json.toInt() : null;
      });
    } catch (e) {
      debugPrint('Kontaktanfragen nicht abrufbar: $e');
      return null;
    }
  }

  static Future<void> answerContactRequest(
    int requesterId, {
    required bool accept,
  }) {
    return _withTokens<void>((t) async {
      await _call(
        t.token,
        accept
            ? 'core_message_confirm_contact_request'
            : 'core_message_decline_contact_request',
        params: {
          'userid': requesterId.toString(),
          'requesteduserid': t.userId.toString(),
        },
      );
    });
  }

  // ---------- Dateien aus Moodle-Links ----------

  /// Lädt eine Moodle-Datei (pluginfile.php-Link) mit dem Web-Service-Token
  /// in den temporären Ordner der App.
  static Future<File> downloadFile(String url) {
    return _withTokens<File>((t) async {
      final uri = Uri.parse(url);
      final fileUri = uri.replace(
        path: uri.path.replaceFirst(
          '/pluginfile.php/',
          '/webservice/pluginfile.php/',
        ),
        queryParameters: {...uri.queryParameters, 'token': t.token},
      );
      final res = await http.get(fileUri).timeout(const Duration(seconds: 60));
      final type = res.headers['content-type'] ?? '';
      if (type.contains('application/json')) {
        final json = _decode(res);
        throw MoodleApiException(
          _messageOf(json, 'Datei nicht verfügbar.'),
          code: _codeOf(json),
        );
      }
      if (res.statusCode != 200) {
        throw MoodleApiException(
          'Datei nicht verfügbar (HTTP ${res.statusCode}).',
        );
      }
      var name =
          uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'moodle_datei';
      name = name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      if (!name.contains('.')) name = '$name.bin';
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(res.bodyBytes);
      return file;
    });
  }
}

/// Zeigt die Anmeldung, solange keine Zugangsdaten gespeichert sind,
/// sonst das Dashboard. Reagiert automatisch auf Anmelden/Abmelden.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Credentials?>(
      valueListenable: AuthService.instance.credentials,
      builder: (context, creds, _) =>
          creds == null ? const LoginPage() : const DashboardPage(),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const primaryColor = Color(0xFF1A5276); // Schul-Blau

    return MaterialApp(
      title: 'FES-APP',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryColor,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F6F7),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          elevation: 2,
        ),
      ),
      home: const AuthGate(),
    );
  }
}

// ==========================================
// 0b. LOGIN-SEITE DER APP
// ==========================================
/// Kontextmenü (langer Druck) für die Login-Felder mit garantiertem
/// "Einfügen"-Eintrag. Flutter blendet "Einfügen" aus, wenn es die
/// Zwischenablage nicht als Text erkennt; dann bleibt ein leeres Menü.
/// pasteText() liest die Zwischenablage direkt und umgeht diese Prüfung.
Widget _pasteFriendlyMenu(BuildContext context, EditableTextState state) {
  final items = List<ContextMenuButtonItem>.from(state.contextMenuButtonItems);
  final hasPaste = items.any((i) => i.type == ContextMenuButtonType.paste);
  if (!hasPaste) {
    items.insert(
      0,
      ContextMenuButtonItem(
        type: ContextMenuButtonType.custom,
        label: 'Einfügen',
        onPressed: () {
          state.pasteText(SelectionChangedCause.toolbar);
          state.hideToolbar();
        },
      ),
    );
  }
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: state.contextMenuAnchors,
    buttonItems: items,
  );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _obscure = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final username = _userCtrl.text.trim();
    final password = _passCtrl.text;
    try {
      // Prüft die Zugangsdaten direkt bei Moodle und holt das Token.
      final tokens = await MoodleApi.requestTokens(username, password);
      // Danach wechselt der AuthGate automatisch zum Dashboard.
      await AuthService.instance.save(username, password, tokens);
      await NotificationService.requestPermission();
      await BackgroundSync.enable();
    } on MoodleApiException catch (e) {
      _fail(e.message);
    } catch (e) {
      debugPrint('Anmeldung fehlgeschlagen: $e');
      _fail(
        'Keine Verbindung zu Moodle. Bitte Internetverbindung prüfen und '
        'erneut versuchen.',
      );
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'FES-APP',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1),
        ),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Image.asset(
                    'assets/images/fes_logo.png',
                    height: 120,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => const Icon(
                      Icons.school,
                      size: 60,
                      color: Color(0xFF1A5276),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Anmeldung',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Melde dich einmal mit deinen Moodle-Zugangsdaten an. '
                    'Sie werden verschlüsselt nur auf diesem Gerät gespeichert '
                    'und ausschließlich für die automatische Anmeldung bei '
                    'Moodle verwendet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _userCtrl,
                    contextMenuBuilder: _pasteFriendlyMenu,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Benutzername',
                      prefixIcon: Icon(Icons.person),
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Bitte Benutzername eingeben'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passCtrl,
                    contextMenuBuilder: _pasteFriendlyMenu,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: 'Passwort',
                      prefixIcon: const Icon(Icons.lock),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure ? Icons.visibility : Icons.visibility_off,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    validator: (v) => (v == null || v.isEmpty)
                        ? 'Bitte Passwort eingeben'
                        : null,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _saving ? null : _submit,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: _saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Anmelden'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 1. DASHBOARD GRID (GRÖSSERES LOGO)
// ==========================================
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with WidgetsBindingObserver {
  /// Anzahl Konversationen mit ungelesenen Moodle-Nachrichten
  int? _unreadMessages;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshUnread();
    // Solange die App offen ist, alle 3 Minuten aktualisieren
    _refreshTimer = Timer.periodic(
      const Duration(minutes: 3),
      (_) => _refreshUnread(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshUnread();
  }

  Future<void> _refreshUnread() async {
    final count = await MoodleApi.fetchUnreadCount();
    if (!mounted) return;
    // Bei einem Fehler (null) bleibt der zuletzt bekannte Wert stehen
    if (count != null && count != _unreadMessages) {
      setState(() => _unreadMessages = count);
    }
  }

  Future<void> _testNotification() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await NotificationService.requestPermission();
      final count = await MoodleApi.fetchUnreadCount();
      debugPrint('[BackgroundSync-Test] Ungelesene Nachrichten: $count');
      if (count == null) {
        messenger.showSnackBar(const SnackBar(
          content: Text('Konnte ungelesene Nachrichten nicht abrufen (Verbindungsfehler).'),
        ));
        return;
      }
      // Erzwingt die Anzeige, unabhängig vom zuletzt gemeldeten Stand,
      // rein zum Testen, ob Berechtigung/Kanal funktionieren.
      await NotificationService.showNewMessages(count == 0 ? 1 : count);
      messenger.showSnackBar(SnackBar(
        content: Text(
          'Testbenachrichtigung ausgelöst. Ungelesene laut Moodle: $count',
        ),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Fehler: $e')));
    }
  }

  /// Führt exakt die Logik des echten Hintergrundjobs sofort im Vordergrund
  /// aus und zeigt das Ergebnis in einem Dialog. Kein Warten auf den
  /// Android-Scheduler, kein ADB nötig.
  Future<void> _runDiagnostics() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 16),
            Text('Prüfung läuft …'),
          ],
        ),
      ),
    );
    final result = await BackgroundSync.performCheck(logPrefix: '[Sync-Diagnose]');
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // Lade-Dialog schließen

    final lines = <String>[
      'Zugangsdaten gefunden: ${result.hadCredentials ? "ja" : "nein"}',
      if (result.error != null) 'Fehler: ${result.error}',
      if (result.unreadCount != null) 'Ungelesene Unterhaltungen: ${result.unreadCount}',
      if (result.lastNotified != null) 'Zuletzt gemeldete Nachrichten-ID: ${result.lastNotified}',
      'Benachrichtigung ausgelöst: ${result.notified ? "JA" : "nein"}',
    ];

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Diagnose-Ergebnis'),
        content: Text(lines.join('\n')),
        actions: [
          TextButton(
            onPressed: () async {
              await BackgroundSync.resetLastNotified();
              if (ctx.mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Zurückgesetzt. Nächste Prüfung meldet wieder, auch bei gleicher Zahl.',
                    ),
                  ),
                );
              }
            },
            child: const Text('Zurücksetzen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Ok'),
          ),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Abmelden?'),
        content: const Text(
          'Deine gespeicherten Zugangsdaten werden von diesem Gerät gelöscht.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Abmelden'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // Moodle-Session im WebView beenden und Zugangsdaten samt Token löschen.
    // Der AuthGate zeigt danach automatisch wieder die Anmeldung.
    await WebViewCookieManager().clearCookies();
    await BackgroundSync.disable();
    await AuthService.instance.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'FES-APP',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1),
        ),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'logout') _logout();
              if (value == 'testNotify') _testNotification();
              if (value == 'diagnose') _runDiagnostics();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'testNotify',
                child: Text('Benachrichtigung testen'),
              ),
              PopupMenuItem(
                value: 'diagnose',
                child: Text('Hintergrundprüfung jetzt ausführen'),
              ),
              PopupMenuItem(value: 'logout', child: Text('Abmelden')),
            ],
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            // Logo-Container mit mehr Höhe
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 6,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Image.asset(
                'assets/images/fes_logo.png',
                height: 200, // logo höhe
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => const Icon(
                  Icons.school,
                  size: 60,
                  color: Color(0xFF1A5276),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Wähle einen Bereich aus:',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                children: [
                  _buildTile(
                    context,
                    title: 'Moodle',
                    icon: Icons.school_rounded,
                    color: const Color(0xFFE67E22),
                    url: 'https://moodle.fes-pforzheim.de/moodle/',
                  ),
                  _buildTile(
                    context,
                    title: 'Vertretungsplan',
                    icon: Icons.calendar_month_rounded,
                    color: const Color(0xFF27AE60),
                    url: 'https://moodle.fes-pforzheim.de/moodle/course/view.php?id=1517',
                  ),
                  _buildTile(
                    context,
                    title: 'Krankmeldung',
                    icon: Icons.assignment_turned_in_rounded,
                    color: const Color(0xFFC0392B),
                    url: 'https://www.fes-pforzheim.de/entschuldigungsformular',
                  ),
                  _buildTile(
                    context,
                    title: 'Nachrichten',
                    icon: Icons.mail_rounded,
                    color: const Color(0xFF2980B9),
                    url: kMessagesUrl,
                    badge: _unreadMessages ?? 0,
                    // Native Ansicht statt der (auf dem Handy schlecht lesbaren)
                    // Moodle-Seite
                    pageBuilder: (context) => const MessagesPage(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTile(
    BuildContext context, {
    required String title,
    required IconData icon,
    required Color color,
    required String url,
    int badge = 0,
    WidgetBuilder? pageBuilder,
  }) {
    final iconCircle = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 36, color: color),
    );

    return Card(
      elevation: 2,
      shadowColor: Colors.black12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: pageBuilder ??
                  (context) => WebViewPage(initialUrl: url, title: title),
            ),
          );
          // Nach der Rückkehr ist die Nachrichten-Zahl evtl. nicht mehr aktuell
          _refreshUnread();
        },
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              badge > 0
                  ? Badge(
                      label: Text(badge > 99 ? '99+' : '$badge'),
                      child: iconCircle,
                    )
                  : iconCircle,
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF34495E),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 1b. NACHRICHTEN (native Ansicht über die Moodle-Web-Services)
// ==========================================
class ChatMessage {
  final int id;
  final int fromUserId;
  final String text;
  final int time; // Unix-Sekunden
  const ChatMessage({
    required this.id,
    required this.fromUserId,
    required this.text,
    required this.time,
  });
}

class Conversation {
  final int id;
  final String name;

  /// 1 = einzeln, 2 = Gruppe, 3 = privat (Notizen an sich selbst)
  final int type;
  final int unread;
  final ChatMessage? last;

  /// Darf der Nutzer Nachrichten hier für alle Beteiligten löschen?
  final bool canDeleteForAll;
  const Conversation({
    required this.id,
    required this.name,
    required this.type,
    required this.unread,
    required this.last,
    this.canDeleteForAll = false,
  });
}

class ConversationsResult {
  final int myUserId;
  final List<Conversation> items;
  const ConversationsResult({required this.myUserId, required this.items});
}

class MessagesResult {
  final int myUserId;
  final List<ChatMessage> messages;
  final Map<int, String> names;
  const MessagesResult({
    required this.myUserId,
    required this.messages,
    required this.names,
  });
}

class MoodleUser {
  final int id;
  final String name;
  final bool isContact;
  final bool canMessage;
  final bool requiresContact;
  final bool requestPending;
  const MoodleUser({
    required this.id,
    required this.name,
    this.isContact = false,
    this.canMessage = true,
    this.requiresContact = false,
    this.requestPending = false,
  });
}

/// Ergebnis der Personensuche: Person, mit der eine Unterhaltung beginnt.
class NewChatTarget {
  final Conversation conversation;
  final int userId;
  const NewChatTarget({required this.conversation, required this.userId});
}

/// Wandelt den HTML-Text einer Moodle-Nachricht in einfachen Text um.
String htmlToText(String html) {
  // Links: <a href="URL">Text</a> -> URL (bzw. "Text (URL)"), damit sie
  // in der Nachricht anklickbar bleiben
  final withLinks = html.replaceAllMapped(
    RegExp(
      r'<a\s[^>]*?href\s*=\s*["\x27]([^"\x27]+)["\x27][^>]*>(.*?)</a>',
      caseSensitive: false,
      dotAll: true,
    ),
    (m) {
      final href = m.group(1)!;
      final inner = m.group(2)!.replaceAll(RegExp(r'<[^>]*>'), '').trim();
      if (inner.isEmpty ||
          inner == href ||
          inner.startsWith('http') ||
          inner.startsWith('www.')) {
        return href;
      }
      return '$inner ($href)';
    },
  );
  var t = withLinks
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), '');
  t = t
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return t.trim();
}

String describeApiError(Object e) {
  if (e is MoodleApiException) return e.message;
  return 'Keine Verbindung zu Moodle. Bitte Internetverbindung prüfen.';
}

String _two(int n) => n.toString().padLeft(2, '0');

String formatClock(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
  return '${_two(d.hour)}:${_two(d.minute)}';
}

String formatListTime(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
  final now = DateTime.now();
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return formatClock(ts);
  }
  if (d.year == now.year) return '${_two(d.day)}.${_two(d.month)}.';
  return '${_two(d.day)}.${_two(d.month)}.${_two(d.year % 100)}';
}

String formatDayLabel(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Heute';
  if (diff == 1) return 'Gestern';
  return '${_two(d.day)}.${_two(d.month)}.${d.year}';
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result == true;
}

/// Öffnet die Moodle-Nachrichtenseite im WebView (für Funktionen, die die
/// native Ansicht nicht kann).
void openMessagesInMoodle(BuildContext context) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) =>
          const WebViewPage(initialUrl: kMessagesUrl, title: 'Nachrichten'),
    ),
  );
}

/// Lädt eine Moodle-Datei und öffnet sie (oder bietet "Teilen" an).
Future<void> openMoodleFile(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    const SnackBar(
      content: Text('Datei wird geladen …'),
      duration: Duration(seconds: 2),
    ),
  );
  try {
    final file = await MoodleApi.downloadFile(url);
    final result = await OpenFilex.open(file.path);
    if (result.type != ResultType.done) {
      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Datei speichern oder teilen',
      );
    }
  } catch (e) {
    debugPrint('Datei-Download fehlgeschlagen: $e');
    messenger.showSnackBar(
      SnackBar(
        content: Text('Datei konnte nicht geladen werden. ${describeApiError(e)}'),
      ),
    );
  }
}

/// Behandelt einen angetippten Link aus einer Nachricht:
/// Moodle-Dateien werden geladen, andere Moodle-Seiten in der App geöffnet,
/// externe Links erst nach Rückfrage im Browser.
Future<void> handleLinkTap(BuildContext context, String rawUrl) async {
  final url =
      rawUrl.toLowerCase().startsWith('www.') ? 'https://$rawUrl' : rawUrl;
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) return;

  if (uri.host == kMoodleHost) {
    if (uri.path.contains('/pluginfile.php/')) {
      await openMoodleFile(context, url);
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => WebViewPage(initialUrl: url, title: 'Moodle'),
        ),
      );
    }
    return;
  }

  final ok = await confirmDialog(
    context,
    title: 'Externen Link öffnen?',
    message: url,
    confirmLabel: 'Öffnen',
  );
  if (!ok || !context.mounted) return;
  final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!launched && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Link konnte nicht geöffnet werden.')),
    );
  }
}

final RegExp _urlRegex =
    RegExp(r'(https?://|www\.)[^\s<>]+', caseSensitive: false);
const String _trailingPunctuation = '.,;:!?)]}\'"';

/// Text mit anklickbaren Links.
class LinkifiedText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final TextStyle linkStyle;
  final ValueChanged<String> onLinkTap;
  const LinkifiedText({
    super.key,
    required this.text,
    required this.style,
    required this.linkStyle,
    required this.onLinkTap,
  });

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  final List<TapGestureRecognizer> _recognizers = [];

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final text = widget.text;
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _urlRegex.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      var url = m.group(0)!;
      var trailing = '';
      // Satzzeichen am Ende gehören nicht zum Link
      while (url.isNotEmpty &&
          _trailingPunctuation.contains(url[url.length - 1])) {
        trailing = url[url.length - 1] + trailing;
        url = url.substring(0, url.length - 1);
      }
      if (url.isEmpty) {
        spans.add(TextSpan(text: m.group(0)));
      } else {
        final linkUrl = url;
        final recognizer = TapGestureRecognizer()
          ..onTap = () => widget.onLinkTap(linkUrl);
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(text: url, style: widget.linkStyle, recognizer: recognizer),
        );
        if (trailing.isNotEmpty) spans.add(TextSpan(text: trailing));
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onOpenMoodle;
  const _ErrorView({
    required this.message,
    required this.onRetry,
    required this.onOpenMoodle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onRetry,
              child: const Text('Erneut versuchen'),
            ),
            TextButton(
              onPressed: onOpenMoodle,
              child: const Text('In Moodle öffnen'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String name;
  final bool group;
  const _Avatar({required this.name, required this.group});

  String get _initials {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return CircleAvatar(
      radius: 22,
      backgroundColor: primary.withOpacity(0.15),
      child: group
          ? Icon(Icons.group, color: primary)
          : Text(
              _initials,
              style: TextStyle(color: primary, fontWeight: FontWeight.bold),
            ),
    );
  }
}

// ---------- Liste der Unterhaltungen ----------
class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  ConversationsResult? _data;
  String? _error;
  bool _loading = true;
  int _requestCount = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _loadRequestCount();
    // Solange die Liste offen ist, alle 30 Sekunden aktualisieren
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      _load(silent: true);
      _loadRequestCount();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final result = await MoodleApi.fetchConversations();
      if (!mounted) return;
      setState(() {
        _data = result;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      debugPrint('Unterhaltungen nicht ladbar: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_data == null) _error = describeApiError(e);
      });
      if (!silent && _data != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(describeApiError(e))),
        );
      }
    }
  }

  Future<void> _loadRequestCount() async {
    final count = await MoodleApi.fetchContactRequestCount();
    if (!mounted || count == null || count == _requestCount) return;
    setState(() => _requestCount = count);
  }

  Future<void> _startNewConversation() async {
    final target = await Navigator.push<NewChatTarget>(
      context,
      MaterialPageRoute(builder: (context) => const NewConversationPage()),
    );
    if (target != null && mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ConversationPage(
            conversation: target.conversation,
            newUserId: target.userId,
          ),
        ),
      );
    }
    _load(silent: true);
  }

  Future<void> _openContactRequests() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const ContactRequestsPage()),
    );
    _loadRequestCount();
  }

  Future<void> _confirmDelete(Conversation c) async {
    final ok = await confirmDialog(
      context,
      title: 'Unterhaltung löschen?',
      message: 'Die Unterhaltung mit „${c.name}“ wird nur für dich gelöscht.',
      confirmLabel: 'Löschen',
    );
    if (!ok || !mounted) return;
    try {
      await MoodleApi.deleteConversation(c.id);
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Löschen nicht möglich. ${describeApiError(e)}'),
        ),
      );
    }
  }

  String _preview(Conversation c, int myId) {
    final last = c.last;
    if (last == null) return 'Noch keine Nachrichten';
    final text = last.text.replaceAll('\n', ' ');
    return last.fromUserId == myId ? 'Du: $text' : text;
  }

  Widget _tile(Conversation c, int myId) {
    final primary = Theme.of(context).colorScheme.primary;
    final unread = c.unread > 0;
    return InkWell(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ConversationPage(conversation: c),
          ),
        );
        _load(silent: true);
      },
      onLongPress: () => _confirmDelete(c),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            _Avatar(name: c.name, group: c.type == 2),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: unread ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _preview(c, myId),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: unread ? Colors.black87 : Colors.grey.shade600,
                      fontWeight: unread ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  c.last == null ? '' : formatListTime(c.last!.time),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 4),
                if (unread)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      c.unread > 99 ? '99+' : '${c.unread}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  )
                else
                  const SizedBox(height: 20),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    final data = _data;
    if (data == null) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return _ErrorView(
        message: _error ?? 'Unbekannter Fehler.',
        onRetry: () {
          setState(() {
            _loading = true;
            _error = null;
          });
          _load();
        },
        onOpenMoodle: () => openMessagesInMoodle(context),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(),
      child: data.items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 120),
                Center(child: Text('Keine Unterhaltungen vorhanden.')),
              ],
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: data.items.length,
              separatorBuilder: (context, index) =>
                  const Divider(height: 1, indent: 74),
              itemBuilder: (context, index) =>
                  _tile(data.items[index], data.myUserId),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nachrichten'),
        actions: [
          IconButton(
            icon: _requestCount > 0
                ? Badge(
                    label: Text('$_requestCount'),
                    child: const Icon(Icons.person_add_alt),
                  )
                : const Icon(Icons.person_add_alt),
            tooltip: 'Kontaktanfragen',
            onPressed: _openContactRequests,
          ),
          IconButton(
            icon: const Icon(Icons.open_in_browser),
            tooltip: 'In Moodle öffnen',
            onPressed: () => openMessagesInMoodle(context),
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startNewConversation,
        icon: const Icon(Icons.edit),
        label: const Text('Neue Nachricht'),
      ),
    );
  }
}

// ---------- Eine Unterhaltung ----------
class ConversationPage extends StatefulWidget {
  final Conversation conversation;

  /// Nur bei einer noch nicht angelegten Unterhaltung (conversation.id == 0):
  /// die Person, an die die erste Nachricht geht.
  final int? newUserId;
  const ConversationPage({
    super.key,
    required this.conversation,
    this.newUserId,
  });

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  final _textCtrl = TextEditingController();
  late int _convId = widget.conversation.id;
  MessagesResult? _data;
  String? _error;
  bool _loading = true;
  bool _sending = false;
  int _lastSeenId = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    // Solange die Unterhaltung offen ist, alle 10 Sekunden nach Neuem schauen
    _timer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (_convId == 0) {
      // Neue Unterhaltung: es gibt noch nichts zu laden
      if (mounted && _loading) setState(() => _loading = false);
      return;
    }
    try {
      final result = await MoodleApi.fetchMessages(_convId);
      if (!mounted) return;
      setState(() {
        _data = result;
        _error = null;
        _loading = false;
      });
      _markReadIfNeeded(result);
    } catch (e) {
      debugPrint('Nachrichten nicht ladbar: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_data == null) _error = describeApiError(e);
      });
    }
  }

  /// Markiert die Unterhaltung als gelesen, sobald es neue Nachrichten gibt.
  void _markReadIfNeeded(MessagesResult result) {
    final newest = result.messages.isEmpty ? 0 : result.messages.last.id;
    if (newest == _lastSeenId) return;
    _lastSeenId = newest;
    MoodleApi.markConversationRead(_convId);
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      if (_convId == 0) {
        final userId = widget.newUserId;
        if (userId == null) {
          throw const MoodleApiException('Empfänger unbekannt.');
        }
        // Die erste Nachricht legt die Unterhaltung an
        _convId = await MoodleApi.sendInstantMessage(userId, text);
      } else {
        await MoodleApi.sendMessage(_convId, text);
      }
      _textCtrl.clear();
      await _load(silent: true);
    } catch (e) {
      debugPrint('Senden fehlgeschlagen: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Nachricht konnte nicht gesendet werden. ${describeApiError(e)}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _showMessageMenu(ChatMessage m) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Text kopieren'),
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Für mich löschen'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            if (widget.conversation.canDeleteForAll)
              ListTile(
                leading: const Icon(Icons.delete_forever),
                title: const Text('Für alle löschen'),
                onTap: () => Navigator.pop(ctx, 'deleteAll'),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;

    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: m.text));
      _snack('Text kopiert.');
      return;
    }

    final forAll = action == 'deleteAll';
    final ok = await confirmDialog(
      context,
      title: forAll ? 'Für alle löschen?' : 'Nachricht löschen?',
      message: forAll
          ? 'Die Nachricht wird für alle Beteiligten gelöscht.'
          : 'Die Nachricht wird nur für dich gelöscht.',
      confirmLabel: 'Löschen',
    );
    if (!ok || !mounted) return;
    try {
      await MoodleApi.deleteMessage(m.id, forAll: forAll);
      await _load(silent: true);
    } catch (e) {
      _snack('Löschen nicht möglich. ${describeApiError(e)}');
    }
  }

  Future<void> _deleteConversation() async {
    final ok = await confirmDialog(
      context,
      title: 'Unterhaltung löschen?',
      message:
          'Die Unterhaltung mit „${widget.conversation.name}“ wird nur für dich gelöscht.',
      confirmLabel: 'Löschen',
    );
    if (!ok || !mounted) return;
    try {
      await MoodleApi.deleteConversation(_convId);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _snack('Löschen nicht möglich. ${describeApiError(e)}');
    }
  }

  Widget _dayChip(DateTime day) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black12,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          formatDayLabel(day),
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
      ),
    );
  }

  Widget _bubble(ChatMessage m, MessagesResult data) {
    final scheme = Theme.of(context).colorScheme;
    final mine = m.fromUserId == data.myUserId;
    final showName = !mine && widget.conversation.type == 2;
    final senderName = data.names[m.fromUserId] ?? '';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _showMessageMenu(m),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.8,
          ),
          decoration: BoxDecoration(
            color: mine ? scheme.primary : Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(color: Colors.black12, blurRadius: 2),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showName && senderName.isNotEmpty)
                Text(
                  senderName,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: scheme.primary,
                  ),
                ),
              LinkifiedText(
                text: m.text,
                style: TextStyle(
                  fontSize: 15,
                  color: mine ? Colors.white : Colors.black87,
                ),
                linkStyle: TextStyle(
                  fontSize: 15,
                  color: mine
                      ? Colors.lightBlueAccent.shade100
                      : Colors.blue.shade700,
                  decoration: TextDecoration.underline,
                ),
                onLinkTap: (url) => handleLinkTap(context, url),
              ),
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.bottomRight,
                child: Text(
                  formatClock(m.time),
                  style: TextStyle(
                    fontSize: 11,
                    color: mine ? Colors.white70 : Colors.grey,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessages() {
    if (_convId == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Schreibe die erste Nachricht an ${widget.conversation.name}.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    final data = _data;
    if (data == null) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return _ErrorView(
        message: _error ?? 'Unbekannter Fehler.',
        onRetry: () {
          setState(() {
            _loading = true;
            _error = null;
          });
          _load();
        },
        onOpenMoodle: () => openMessagesInMoodle(context),
      );
    }
    if (data.messages.isEmpty) {
      return const Center(child: Text('Noch keine Nachrichten.'));
    }

    // Einträge (Tages-Trenner + Nachrichten), älteste zuerst
    final entries = <Object>[];
    DateTime? lastDay;
    for (final m in data.messages) {
      final d = DateTime.fromMillisecondsSinceEpoch(m.time * 1000);
      final day = DateTime(d.year, d.month, d.day);
      if (lastDay == null || day != lastDay) {
        entries.add(day);
        lastDay = day;
      }
      entries.add(m);
    }

    // reverse: Die Liste beginnt unten und zeigt immer die neueste Nachricht
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[entries.length - 1 - index];
        if (entry is DateTime) return _dayChip(entry);
        return _bubble(entry as ChatMessage, data);
      },
    );
  }

  Widget _buildInputBar() {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _textCtrl,
                minLines: 1,
                maxLines: 5,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Nachricht schreiben …',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Material(
              color: primary,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _sending ? null : _send,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _sending
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send, color: Colors.white, size: 20),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.conversation.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Aktualisieren',
            onPressed: () => _load(),
          ),
          if (_convId != 0)
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'delete') _deleteConversation();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'delete',
                  child: Text('Unterhaltung löschen'),
                ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildMessages()),
          _buildInputBar(),
        ],
      ),
    );
  }
}

// ---------- Neue Unterhaltung: Personensuche ----------
class NewConversationPage extends StatefulWidget {
  const NewConversationPage({super.key});

  @override
  State<NewConversationPage> createState() => _NewConversationPageState();
}

class _NewConversationPageState extends State<NewConversationPage> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<MoodleUser> _results = const [];
  bool _searching = false;
  bool _opening = false;
  String? _error;
  String _lastQuery = '';
  int _searchToken = 0;
  final Set<int> _requested = {};

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < 2) {
      _searchToken++;
      setState(() {
        _results = const [];
        _searching = false;
        _error = null;
        _lastQuery = query;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(query));
  }

  Future<void> _search(String query) async {
    final token = ++_searchToken;
    setState(() {
      _searching = true;
      _error = null;
      _lastQuery = query;
    });
    try {
      final results = await MoodleApi.searchUsers(query);
      if (!mounted || token != _searchToken) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } catch (e) {
      debugPrint('Suche fehlgeschlagen: $e');
      if (!mounted || token != _searchToken) return;
      setState(() {
        _searching = false;
        _error = describeApiError(e);
      });
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _open(MoodleUser user) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      // Gibt es schon eine Unterhaltung mit dieser Person? Dann diese öffnen.
      final existing = await MoodleApi.findConversationWith(user.id);
      if (!mounted) return;
      Navigator.pop(
        context,
        NewChatTarget(
          conversation: Conversation(
            id: existing ?? 0,
            name: user.name,
            type: 1,
            unread: 0,
            last: null,
          ),
          userId: user.id,
        ),
      );
    } catch (e) {
      _snack(describeApiError(e));
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _sendRequest(MoodleUser user) async {
    try {
      await MoodleApi.createContactRequest(user.id);
      if (!mounted) return;
      setState(() => _requested.add(user.id));
      _snack('Kontaktanfrage an ${user.name} gesendet.');
    } catch (e) {
      _snack('Anfrage nicht möglich. ${describeApiError(e)}');
    }
  }

  Widget _userTile(MoodleUser user) {
    final requested = user.requestPending || _requested.contains(user.id);
    String? subtitle;
    Widget? trailing;
    VoidCallback? onTap;
    if (user.canMessage) {
      onTap = () => _open(user);
    } else if (user.requiresContact) {
      subtitle = 'Zuerst ist eine Kontaktanfrage nötig';
      trailing = requested
          ? const Text('Angefragt', style: TextStyle(color: Colors.grey))
          : TextButton(
              onPressed: () => _sendRequest(user),
              child: const Text('Anfragen'),
            );
    } else {
      subtitle = 'Kann nicht angeschrieben werden';
    }
    return ListTile(
      leading: _Avatar(name: user.name, group: false),
      title: Text(user.name),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: trailing,
      onTap: onTap,
    );
  }

  Widget _buildResults() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (_lastQuery.length < 2) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Gib mindestens 2 Zeichen des Namens ein.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    if (_results.isEmpty && !_searching) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Keine Personen gefunden. Wen du anschreiben darfst, legt Moodle fest.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    final contacts = _results.where((u) => u.isContact).toList();
    final others = _results.where((u) => !u.isContact).toList();
    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
        );
    return ListView(
      children: [
        if (contacts.isNotEmpty) header('KONTAKTE'),
        ...contacts.map(_userTile),
        if (others.isNotEmpty) header('WEITERE PERSONEN'),
        ...others.map(_userTile),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Neue Nachricht')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchCtrl,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              decoration: InputDecoration(
                hintText: 'Name suchen …',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
          if (_searching || _opening) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }
}

// ---------- Erhaltene Kontaktanfragen ----------
class ContactRequestsPage extends StatefulWidget {
  const ContactRequestsPage({super.key});

  @override
  State<ContactRequestsPage> createState() => _ContactRequestsPageState();
}

class _ContactRequestsPageState extends State<ContactRequestsPage> {
  List<MoodleUser>? _items;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await MoodleApi.fetchContactRequests();
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      debugPrint('Kontaktanfragen nicht ladbar: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = describeApiError(e);
      });
    }
  }

  Future<void> _answer(MoodleUser user, {required bool accept}) async {
    try {
      await MoodleApi.answerContactRequest(user.id, accept: accept);
      if (!mounted) return;
      setState(() => _items = _items?.where((u) => u.id != user.id).toList());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            accept
                ? '${user.name} ist jetzt in deinen Kontakten.'
                : 'Anfrage von ${user.name} abgelehnt.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Aktion nicht möglich. ${describeApiError(e)}')),
      );
    }
  }

  Widget _buildBody() {
    final items = _items;
    if (items == null) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return _ErrorView(
        message: _error ?? 'Unbekannter Fehler.',
        onRetry: () {
          setState(() {
            _loading = true;
            _error = null;
          });
          _load();
        },
        onOpenMoodle: () => openMessagesInMoodle(context),
      );
    }
    if (items.isEmpty) {
      return const Center(child: Text('Keine offenen Kontaktanfragen.'));
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final user = items[index];
        return ListTile(
          leading: _Avatar(name: user.name, group: false),
          title: Text(user.name),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.check_circle, color: Colors.green),
                tooltip: 'Annehmen',
                onPressed: () => _answer(user, accept: true),
              ),
              IconButton(
                icon: const Icon(Icons.cancel, color: Colors.redAccent),
                tooltip: 'Ablehnen',
                onPressed: () => _answer(user, accept: false),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kontaktanfragen')),
      body: _buildBody(),
    );
  }
}

// ==========================================
// 2. WEBVIEW ENGINE & DUAL ROUTING HANDLER
// ==========================================
class WebViewPage extends StatefulWidget {
  final String initialUrl;
  final String title;
  const WebViewPage({super.key, required this.initialUrl, required this.title});

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> {
  late final WebViewController _controller;
  bool _isLoading = true;

  /// true, sobald wir das Moodle-Loginformular abgeschickt haben und auf das
  /// Ergebnis warten. Erscheint danach erneut die Login-Seite, war der Login
  /// fehlgeschlagen (z. B. Passwort geändert) -> zurück zur App-Anmeldung.
  bool _loginSubmitted = false;

  /// true, solange die Moodle-Anmeldeseite (bzw. der Ladevorgang) hinter einem
  /// Lade-Bildschirm versteckt wird, damit die Nutzer den Auto-Login nicht sehen.
  bool _autoLoggingIn = false;

  /// Sicherheitsnetz: der Lade-Bildschirm verschwindet spätestens nach 15 s.
  Timer? _overlayTimeout;

  /// Verzögertes Ausblenden des Lade-Bildschirms (wird abgebrochen, sobald
  /// eine neue Navigation startet).
  Timer? _hideDebounce;

  /// true, sobald in diesem Durchlauf die Login-Seite aufgetaucht ist.
  bool _sawLoginPage = false;

  /// true, wenn der Nutzer gerade "Zurück" gedrückt hat. Landet die Zurück-
  /// Navigation auf der Login-Seite, verlassen wir die Seite, statt erneut
  /// automatisch einzuloggen.
  bool _goingBack = false;

  @override
  void initState() {
    super.initState();

    // Moodle-Seiten starten hinter dem Lade-Bildschirm (nur wenn wir
    // Zugangsdaten haben, sonst gäbe es ja keinen Auto-Login).
    if (Uri.tryParse(widget.initialUrl)?.host == kMoodleHost &&
        AuthService.instance.credentials.value != null) {
      _autoLoggingIn = true;
      _overlayTimeout = Timer(
        const Duration(seconds: 15),
        () => _hideLoginOverlay(reason: 'Timeout (15 s)'),
      );
    }

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'FileDownloader',
        onMessageReceived: (JavaScriptMessage message) {
          _handleDownloadedData(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            _log('gestartet: $url');
            _hideDebounce?.cancel(); // neue Navigation -> Ausblenden abbrechen
            if (mounted) setState(() => _isLoading = true);
            if (_isAutoLoginPage(url)) _showLoginOverlay();
          },
          onWebResourceError: (WebResourceError error) {
            _log('Ladefehler ${error.errorCode}: ${error.description} '
                '(Hauptframe: ${error.isForMainFrame})');
            // Nur ausblenden, wenn wir nicht gerade auf das Login-Ergebnis warten
            if (error.isForMainFrame != false && !_loginSubmitted) {
              _hideLoginOverlay(reason: 'Ladefehler im Hauptframe');
            }
          },
          onPageFinished: (String url) {
            _log('fertig: $url');
            if (mounted) setState(() => _isLoading = false);
            _handleAutoLogin(url);
          },
          onNavigationRequest: (NavigationRequest request) async {
            final url = request.url;
            final lowerUrl = url.toLowerCase();

            _log('Navigation: $url (Hauptframe: ${request.isMainFrame})');
            if (request.isMainFrame) _hideDebounce?.cancel();

            // Weiterleitung auf die Login-Seite: sofort verstecken
            if (_isAutoLoginPage(url)) _showLoginOverlay();

            if (lowerUrl.contains('redirect=1') ||
                (lowerUrl.contains('/mod/resource/view.php') &&
                    !lowerUrl.contains('forcedownload=1'))) {
              return NavigationDecision.navigate;
            }

            bool isDownload = lowerUrl.contains('forcedownload=1') ||
                (lowerUrl.contains('pluginfile.php') &&
                    !lowerUrl.contains('.html') &&
                    !lowerUrl.contains('.htm'));

            if (isDownload) {
              _triggerJsDownload(url);
              return NavigationDecision.prevent;
            }

            return NavigationDecision.navigate;
          },
        ),
      );

    // Android Cookie-Steuerung (betrifft Drittanbieter-Cookies, sorgt allein
    // NICHT für dauerhafte Anmeldung - dafür ist der Auto-Login unten da)
    if (_controller.platform is AndroidWebViewController) {
      AndroidWebViewCookieManager(
        const PlatformWebViewCookieManagerCreationParams(),
      ).setAcceptThirdPartyCookies(
        _controller.platform as AndroidWebViewController,
        true,
      );
    }

    _openInitialUrl();
  }

  /// Öffnet die Startseite. Moodle-Seiten werden zuerst über einen
  /// Auto-Login-Schlüssel (Web-Service) geöffnet, damit gar keine Login-Seite
  /// erscheint. Klappt das nicht (z. B. Mindestabstand zwischen Schlüsseln,
  /// Admin-Konto), wird die Seite direkt geladen; der Formular-Auto-Login
  /// weiter unten fängt dann eine eventuelle Login-Seite ab (Fallback).
  Future<void> _openInitialUrl() async {
    var url = widget.initialUrl;
    if (Uri.tryParse(url)?.host == kMoodleHost &&
        AuthService.instance.credentials.value != null) {
      final autologinUrl = await MoodleApi.buildAutologinUrl(url);
      _log(autologinUrl != null
          ? 'Auto-Login-Schlüssel erhalten'
          : 'kein Auto-Login-Schlüssel, lade Seite direkt');
      if (autologinUrl != null) url = autologinUrl;
    }
    if (!mounted) return;
    await _controller.loadRequest(Uri.parse(url));
  }

  // ------------------------------------------
  // Auto-Login bei Moodle
  // ------------------------------------------
  /// Die FES nutzt das Exabis-2FA-Plugin als Anmeldeseite (Moodle leitet
  /// nicht angemeldete Nutzer nach /blocks/exa2fa/login/ um). Zusätzlich
  /// bleibt der Standard-Pfad von Moodle erkannt.
  bool _isMoodleLoginPage(Uri uri) {
    if (uri.host != kMoodleHost) return false;
    final path = uri.path.endsWith('/')
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    return path.endsWith('/blocks/exa2fa/login') ||
        path.endsWith('/blocks/exa2fa/login/index.php') ||
        path.endsWith('/login/index.php');
  }

  Future<void> _handleAutoLogin(String url) async {
    final uri = Uri.tryParse(url);
    // Nur auf der Moodle-Domain, niemals auf fremden Seiten!
    if (uri == null || uri.host != kMoodleHost) {
      _goingBack = false;
      _hideLoginOverlay(reason: 'Seite außerhalb von Moodle');
      return;
    }

    _log('-> Login-Seite: ${_isMoodleLoginPage(uri)}');

    if (!_isMoodleLoginPage(uri)) {
      // Eine normale Moodle-Seite ist geladen -> angemeldet.
      _loginSubmitted = false;
      _goingBack = false;
      // Nach einem Login kurz warten, bis der WebView die neue Seite wirklich
      // zeigt (sonst blitzt teils noch die Login-Seite auf).
      _hideLoginOverlay(delayed: _sawLoginPage, reason: 'Moodle-Seite fertig');
      return;
    }

    if (_goingBack) {
      // "Zurück" hat die Login-Seite erreicht -> Seite verlassen statt
      // erneut automatisch einzuloggen.
      _goingBack = false;
      if (mounted) Navigator.of(context).pop();
      return;
    }

    final creds = AuthService.instance.credentials.value;
    if (creds == null) {
      _hideLoginOverlay(reason: 'keine Zugangsdaten');
      return;
    }

    if (_loginSubmitted) {
      // Wir haben das Formular schon abgeschickt und sehen wieder die
      // Login-Seite -> Zugangsdaten stimmen nicht mehr.
      await _onLoginFailed();
      return;
    }

    // jsonEncode sorgt dafür, dass Sonderzeichen im Passwort sicher
    // als JavaScript-String eingesetzt werden.
    // Kein Verlass auf feste IDs: Formular wird über das Passwortfeld gefunden.
    final script = '''
      (function() {
        var p = document.querySelector('input[type="password"]');
        if (!p || !p.form) return 'noform';
        var f = p.form;
        var u = f.querySelector('input[name="username"]') ||
                f.querySelector('input[type="text"], input[type="email"]');
        if (!u) return 'noform';
        u.value = ${jsonEncode(creds.username)};
        p.value = ${jsonEncode(creds.password)};
        u.dispatchEvent(new Event('input', { bubbles: true }));
        p.dispatchEvent(new Event('input', { bubbles: true }));
        var b = f.querySelector('button[type="submit"], input[type="submit"], #loginbtn');
        if (b) { b.click(); } else { f.submit(); }
        return 'submitted';
      })();
    ''';

    _loginSubmitted = true; // vor dem Absenden setzen (Race-Condition vermeiden)
    try {
      final result = await _controller.runJavaScriptReturningResult(script);
      debugPrint('[AUTOLOGIN] Ergebnis: $result');
      if (!result.toString().contains('submitted')) {
        _loginSubmitted = false; // Formular nicht gefunden
        _hideLoginOverlay(reason: 'Formular nicht gefunden'); // manuell anmelden
        await _debugDumpElements();
      }
    } catch (e) {
      // Unklar, ob das Formular schon abgeschickt wurde -> Lade-Bildschirm
      // NICHT sofort ausblenden (sonst blitzt die ausgefüllte Login-Seite auf);
      // das Zeitlimit blendet ihn spätestens nach 15 s aus.
      _log('JavaScript-Fehler beim Auto-Login: $e');
    }
  }

  /// Nur zur Fehlersuche: gibt die Formularelemente der Seite im Log aus
  /// (ohne Werte, also ohne Passwort).
  Future<void> _debugDumpElements() async {
    try {
      final r = await _controller.runJavaScriptReturningResult('''
        (function() {
          return Array.from(document.querySelectorAll('form, input, button'))
            .map(function(e) {
              return e.tagName + '[type=' + (e.type || '') +
                     ',name=' + (e.name || '') + ',id=' + (e.id || '') + ']';
            }).join(' ');
        })();
      ''');
      debugPrint('[AUTOLOGIN] Elemente: $r');
    } catch (e) {
      debugPrint('[AUTOLOGIN] Dump fehlgeschlagen: $e');
    }
  }

  Future<void> _onLoginFailed() async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    _loginSubmitted = false;

    // Löscht die gespeicherten Daten -> AuthGate zeigt wieder die Anmeldung.
    await AuthService.instance.clear();
    navigator.popUntil((route) => route.isFirst);
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Anmeldung bei Moodle fehlgeschlagen. Bitte Zugangsdaten erneut eingeben.',
        ),
      ),
    );
  }

  // ------------------------------------------
  // Lade-Bildschirm während des Auto-Logins
  // ------------------------------------------
  bool _isAutoLoginPage(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        _isMoodleLoginPage(uri) &&
        AuthService.instance.credentials.value != null;
  }

  void _log(String message) {
    final t = DateTime.now().toIso8601String().substring(11, 23);
    // Auto-Login-Schlüssel nie im Log zeigen
    final safe = message.replaceAll(RegExp(r'key=[A-Za-z0-9_-]+'), 'key=***');
    debugPrint('[AUTOLOGIN] $t $safe');
  }

  void _showLoginOverlay() {
    if (!mounted) return;
    _sawLoginPage = true;
    _hideDebounce?.cancel();
    if (!_autoLoggingIn) setState(() => _autoLoggingIn = true);
    _overlayTimeout?.cancel();
    _overlayTimeout = Timer(
      const Duration(seconds: 15),
      () => _hideLoginOverlay(reason: 'Timeout (15 s)'),
    );
  }

  void _hideLoginOverlay({bool delayed = false, String reason = ''}) {
    _hideDebounce?.cancel();
    if (delayed) {
      _log('Lade-Bildschirm: Ausblenden in ${kOverlayHideDelay.inMilliseconds} ms geplant ($reason)');
      _hideDebounce = Timer(
        kOverlayHideDelay,
        () => _hideLoginOverlay(reason: '$reason, nach Wartezeit'),
      );
      return;
    }
    _overlayTimeout?.cancel();
    _sawLoginPage = false;
    if (mounted && _autoLoggingIn) {
      _log('Lade-Bildschirm: AUSGEBLENDET, Grund: $reason');
      setState(() => _autoLoggingIn = false);
    }
  }

  // ------------------------------------------
  // Zurück-Navigation
  // ------------------------------------------
  Future<void> _goBackOrExit() async {
    if (await _controller.canGoBack()) {
      _goingBack = true;
      // Sicherheitsnetz: Flag verfällt, falls die Zurück-Navigation kein
      // neues Seiten-Ladeereignis auslöst (z. B. Sprung innerhalb einer Seite).
      Future.delayed(const Duration(seconds: 5), () => _goingBack = false);
      await _controller.goBack();
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _overlayTimeout?.cancel();
    _hideDebounce?.cancel();
    super.dispose();
  }

  // ------------------------------------------
  // Downloads (unverändert)
  // ------------------------------------------
  void _triggerJsDownload(String url) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Datei wird verarbeitet...'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    final jsScript = '''
      (function() {
        fetch("$url")
          .then(response => {
            const disposition = response.headers.get('Content-Disposition');
            let filename = "$url".split('/').pop().split('?')[0] || "moodle_datei";
            if (disposition && disposition.indexOf('filename=') !== -1) {
              const matches = /filename[^;=\\n]*=((['"]).*?\\2|[^;\\n]*)/.exec(disposition);
              if (matches != null && matches[1]) {
                filename = matches[1].replace(/['"]/g, '');
              }
            }
            return response.blob().then(blob => ({ blob, filename }));
          })
          .then(({ blob, filename }) => {
            const reader = new FileReader();
            reader.onloadend = function() {
              const base64data = reader.result.split(',')[1];
              const payload = JSON.stringify({ filename: filename, data: base64data });
              FileDownloader.postMessage(payload);
            };
            reader.readAsDataURL(blob);
          })
          .catch(err => {
            console.error("Download Error", err);
          });
      })();
    ''';

    _controller.runJavaScript(jsScript);
  }

  Future<void> _handleDownloadedData(String jsonString) async {
    try {
      final Map<String, dynamic> payload = jsonDecode(jsonString);
      String fileName = payload['filename'] ?? 'moodle_datei.bin';
      String base64Data = payload['data'] ?? '';

      if (base64Data.isEmpty) return;

      fileName = Uri.decodeFull(fileName);
      fileName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      if (!fileName.contains('.')) fileName = '$fileName.bin';

      final bytes = base64Decode(base64Data);
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(bytes);

      final result = await OpenFilex.open(file.path);

      if (result.type != ResultType.done && mounted) {
        await Share.shareXFiles(
          [XFile(file.path)],
          text: 'Datei speichern oder teilen: $fileName',
        );
      }
    } catch (e) {
      debugPrint('Fehler bei Datenverarbeitung: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _goBackOrExit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _goBackOrExit,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.home),
              tooltip: 'Zum Dashboard',
              onPressed: () => Navigator.of(context).pop(),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Neu laden',
              onPressed: () => _controller.reload(),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_isLoading) const LinearProgressIndicator(minHeight: 3),
            Expanded(
              child: Stack(
                children: [
                  WebViewWidget(controller: _controller),
                  if (_autoLoggingIn) const Positioned.fill(child: _LoginOverlay()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Deckt den WebView ab, solange der Auto-Login läuft.
class _LoginOverlay extends StatelessWidget {
  const _LoginOverlay();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF4F6F7),
      alignment: Alignment.center,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text(
            'Moodle wird geladen …',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}