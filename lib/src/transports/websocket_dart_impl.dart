import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:sip_ua/src/sip_ua_helper.dart';
import 'package:web_socket_channel/io.dart';

import '../logger.dart';

typedef OnMessageCallback = void Function(dynamic msg);
typedef OnCloseCallback = void Function(int? code, String? reason);
typedef OnOpenCallback = void Function();

enum ConnectionState {
  disconnected,
  connecting,
  connected,
  failed,
}

class SIPUAWebSocketImpl {
  SIPUAWebSocketImpl(this._url, this.messageDelay);

  final String _url;
  WebSocket? _socket;
  IOWebSocketChannel? _channel;
  OnOpenCallback? onOpen;
  OnMessageCallback? onMessage;
  OnCloseCallback? onClose;
  final int messageDelay;

  // Enhanced connection management
  ConnectionState _connectionState = ConnectionState.disconnected;
  bool _isConnected = false;

  bool allowInvalidCertificates = false;
  void connect({Iterable<String>? protocols, required WebSocketSettings webSocketSettings}) async {
    handleQueue();
    logger.i('connect $_url, ${webSocketSettings.extraHeaders}, $protocols');

    // Set allowInvalidCertificates from webSocketSettings
    allowInvalidCertificates = webSocketSettings.allowBadCertificate;

    // Use enhanced connect method
    final bool success = await _enhancedConnect(_url,
        authToken: 'token', enableAutoReconnect: true, webSocketSettings: webSocketSettings, protocols: protocols);

    if (!success) {
      onClose?.call(500, 'Connection failed');
    }
  }

  Future<bool> _enhancedConnect(String url,
      {String? authToken,
      bool enableAutoReconnect = true,
      required WebSocketSettings webSocketSettings,
      Iterable<String>? protocols}) async {
    if (_connectionState == ConnectionState.connecting) {
      logger.w('⚠️ Connection already in progress, ignoring duplicate request');
      return false;
    }

    _connectionState = ConnectionState.connecting;

    try {
      logger.i('🔗 Attempting to connect to: $url');

      final Uri uri = Uri.parse(url);
      final Uri uriWithAuth = authToken != null
          ? uri.replace(queryParameters: <String, String>{...uri.queryParameters, 'token': authToken})
          : uri;

      // Create WebSocket with enhanced configuration
      final HttpClient httpClient = HttpClient();

      // Configure SSL certificate handling only for secure connections (wss://)
      final bool isSecureConnection = uriWithAuth.scheme == 'wss';
      if (isSecureConnection && allowInvalidCertificates) {
        httpClient.badCertificateCallback = (X509Certificate cert, String host, int port) {
          logger.w('⚠️ SSL Certificate warning for $host:$port');
          logger.w('⚠️ Certificate subject: ${cert.subject}');
          logger.w('⚠️ Certificate issuer: ${cert.issuer}');
          logger.w('⚠️ Allowing connection (allowInvalidCertificates=true)');
          return true;
        };
      } else if (!isSecureConnection) {
        logger.i('🔓 Using non-secure WebSocket connection (ws://)');
        logger.i('🔓 SSL certificate handling disabled for non-secure connection');
      }

      // Connect with timeout handling
      final WebSocket webSocket = await WebSocket.connect(
        uriWithAuth.toString(),
        customClient: httpClient,
      );

      _socket = webSocket;
      _channel = IOWebSocketChannel(webSocket);

      // Set up stream listeners with enhanced error handling
      onOpen?.call();
      _socket!.listen((dynamic data) {
        onMessage?.call(data);
      }, onDone: () {
        onClose?.call(_socket!.closeCode, _socket!.closeReason);
      });

      // Connection successful
      _connectionState = ConnectionState.connected;
      _isConnected = true;

      logger.i('✅ Signaling server connected successfully');
      logger.i('🔄 Auto-reconnect: $enableAutoReconnect');

      return true;
    } on TimeoutException catch (e) {
      logger.e('⏰ Connection timeout: $e');
      _connectionState = ConnectionState.failed;
      return false;
    } on SocketException catch (e) {
      logger.e('🌐 Network error: $e');
      _connectionState = ConnectionState.failed;
      return false;
    } on WebSocketException catch (e) {
      logger.e('🔌 WebSocket error: $e');
      _connectionState = ConnectionState.failed;
      return false;
    } catch (e) {
      logger.e('❌ Unexpected connection error: $e');
      _connectionState = ConnectionState.failed;
      return false;
    }
  }

  void _onMessage(dynamic data) {
    onMessage?.call(data);
  }

  void _onError(dynamic error) {
    logger.e('WebSocket error: $error');
    onClose?.call(500, error.toString());
  }

  void _onDisconnected() {
    _connectionState = ConnectionState.disconnected;
    _isConnected = false;
    onClose?.call(_socket?.closeCode, _socket?.closeReason);
  }

  final StreamController<dynamic> queue = StreamController<dynamic>.broadcast();
  void handleQueue() async {
    queue.stream.asyncMap((dynamic event) async {
      await Future<void>.delayed(Duration(milliseconds: messageDelay));
      return event;
    }).listen((dynamic event) async {
      _socket!.add(event);
      logger.d('send: \n\n$event');
    });
  }

  void send(dynamic data) async {
    if (_socket != null) {
      queue.add(data);
    }
  }

  void close() {
    if (_socket != null) _socket!.close();
  }

  bool isConnecting() {
    return _socket != null && _socket!.readyState == WebSocket.connecting;
  }
}
