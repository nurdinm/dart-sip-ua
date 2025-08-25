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

  DateTime? _connectionStartTime;
  WebSocketSettings? _webSocketSettings;
  void connect({Iterable<String>? protocols, required WebSocketSettings webSocketSettings}) async {
    handleQueue();
    logger.i('connect $_url');

    // Store connection start time and WebSocket settings
    _connectionStartTime = DateTime.now();
    _webSocketSettings = webSocketSettings;

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
      logger.d('Connecting with protocols: $protocols');
      logger.d('Extra headers: ${webSocketSettings.extraHeaders}');

      // Set up default headers for SIP over WebSocket (RFC 7118)
      Map<String, String> headers = <String, String>{};

      // Add Origin header if not provided (required by many SIP servers)
      if (!webSocketSettings.extraHeaders.containsKey('Origin')) {
        headers['Origin'] = 'https://${uriWithAuth.host}';
      }

      // Add User-Agent if not provided
      if (!webSocketSettings.extraHeaders.containsKey('User-Agent')) {
        headers['User-Agent'] = webSocketSettings.userAgent ?? 'Dart SIP UA Client v1.0.0';
      }

      // Add custom headers from settings
      if (webSocketSettings.extraHeaders.isNotEmpty) {
        headers.addAll(Map<String, String>.from(webSocketSettings.extraHeaders));
        httpClient.userAgent = webSocketSettings.userAgent ?? 'Dart SIP UA Client v1.0.0';
      }

      logger.d('Final headers: $headers');

      final WebSocket webSocket = await WebSocket.connect(
        uriWithAuth.toString(),
        customClient: httpClient,
        headers: headers.isNotEmpty ? headers : null,
      ).timeout(
        Duration(seconds: 30),
        onTimeout: () {
          logger.e('WebSocket connection timeout after 30 seconds');
          throw TimeoutException('WebSocket connection timeout', Duration(seconds: 30));
        },
      );

      logger.d('WebSocket connected with protocol: ${webSocket.protocol}');
      logger.d('WebSocket ready state: ${webSocket.readyState}');

      // Validate protocol negotiation
      if (protocols != null && protocols.isNotEmpty && webSocket.protocol == null) {
        logger.w('⚠️ WebSocket connected but no protocol was negotiated. Expected: $protocols');
      } else if (protocols != null && protocols.isNotEmpty && !protocols.contains(webSocket.protocol)) {
        logger.w('⚠️ WebSocket negotiated unexpected protocol: ${webSocket.protocol}. Expected: $protocols');
      } else {
        logger.i('✅ WebSocket protocol negotiation successful: ${webSocket.protocol}');
      }

      _socket = webSocket;
      _channel = IOWebSocketChannel(webSocket);

      onOpen?.call();
      _socket!.listen((dynamic data) {
        logger.d(
            '📨 Received WebSocket data: ${data.toString().length > 200 ? data.toString().substring(0, 200) + "..." : data.toString()}');
        _handleIncomingData(data);
      }, onDone: () {
        logger.w('🔌 WebSocket connection closed. Code: ${_socket!.closeCode}, Reason: ${_socket!.closeReason}');
        logger.w(
            '🔌 Connection was open for: ${DateTime.now().difference(_connectionStartTime ?? DateTime.now()).inSeconds} seconds');
        onClose?.call(_socket!.closeCode, _socket!.closeReason);
      }, onError: (error) {
        logger.e('❌ WebSocket error occurred: $error');
        logger.e('❌ Error type: ${error.runtimeType}');
        onClose?.call(1006, error.toString());
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
      try {
        if (_socket != null && _socket!.readyState == WebSocket.open) {
          _socket!.add(event);
          logger.d('send 222: \n\n$event');
        } else {
          logger.w('Cannot send message: WebSocket not open (state: ${_socket?.readyState})');
        }
      } catch (error) {
        logger.e('Error sending message: $error');
        // Don't close the connection here, just log the error
      }
    }, onError: (error) {
      logger.e('Queue processing error: $error');
    });
  }

  void send(dynamic data) async {
    if (_socket != null && _socket!.readyState == WebSocket.open) {
      logger.d('Queuing message for send (WebSocket state: ${_socket!.readyState})');
      queue.add(data);
    } else {
      logger.w('Cannot queue message: WebSocket not available or not open (state: ${_socket?.readyState})');
    }
  }

  void close() {
    if (_socket != null) _socket!.close();
  }

  bool isConnecting() {
    return _socket != null && _socket!.readyState == WebSocket.connecting;
  }

  /// Handle incoming WebSocket data, distinguishing between pong frames and regular messages
  void _handleIncomingData(dynamic data) {
    // Regular message handling
    onMessage?.call(data);
  }
}
