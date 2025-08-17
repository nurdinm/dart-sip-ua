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
  Timer? _connectionTimeoutTimer;
  Timer? _reconnectTimer;
  DateTime? _lastConnectionAttempt;
  DateTime? _connectionEstablishedAt;
  String? _lastUrl;
  String? _lastAuthToken;
  bool _shouldAutoReconnect = true;
  int _reconnectAttempts = 0;
  final Duration _connectionTimeout = const Duration(seconds: 30);
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
    _lastConnectionAttempt = DateTime.now();

    try {
      // Clean up existing connection
      if (_channel != null || _socket != null) {
        await _disconnect(disableAutoReconnect: false);
      }

      // Store connection parameters for potential reconnection
      _lastUrl = url;
      _lastAuthToken = authToken;
      _shouldAutoReconnect = enableAutoReconnect;

      logger.i('🔗 Attempting to connect to: $url');

      // Set connection timeout
      _connectionTimeoutTimer?.cancel();
      _connectionTimeoutTimer = Timer(_connectionTimeout, () {
        if (_connectionState == ConnectionState.connecting) {
          logger.w('⏰ Connection timeout after ${_connectionTimeout.inSeconds}s');
          _connectionState = ConnectionState.failed;
          _channel?.sink.close(1000);
          _channel = null;
          _socket?.close();
          _socket = null;

          if (_shouldAutoReconnect) {
            _scheduleReconnect();
          }
        }
      });

      final Uri uri = Uri.parse(url);
      final Uri uriWithAuth = authToken != null
          ? uri.replace(queryParameters: <String, String>{...uri.queryParameters, 'token': authToken})
          : uri;

      if (webSocketSettings.allowBadCertificate) {
        // Use existing bad certificate handling
        // _socket = await _connectForBadCertificate(url, webSocketSettings);

        // Set up listeners for the WebSocket
        _socket!.listen((dynamic data) {
          _onMessage(data);
        }, onDone: () {
          _onDisconnected();
        }, onError: (Object error) {
          _onError(error);
        });
      } else {
        // Create WebSocket with enhanced configuration
        final HttpClient httpClient = HttpClient();
        httpClient.connectionTimeout = _connectionTimeout;

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
        ).timeout(_connectionTimeout);

        _socket = webSocket;
        _channel = IOWebSocketChannel(webSocket);

        // Set up stream listeners with enhanced error handling
        _channel!.stream.listen(_onMessage, onError: _onError, onDone: _onDisconnected, cancelOnError: false);
      }

      // Connection successful
      _connectionTimeoutTimer?.cancel();
      _connectionState = ConnectionState.connected;
      _isConnected = true;
      _connectionEstablishedAt = DateTime.now();
      _reconnectAttempts = 0;

      // Start services
      _startConnectionHealthMonitoring();
      await _processMessageQueue();

      logger.i('✅ Signaling server connected successfully');
      logger.i('🔗 Connection established at: ${_connectionEstablishedAt!.toIso8601String()}');
      logger.i('🔄 Auto-reconnect: $enableAutoReconnect');

      // Call the original onOpen callback
      onOpen?.call();

      return true;
    } on TimeoutException catch (e) {
      logger.e('⏰ Connection timeout: $e');
      _connectionState = ConnectionState.failed;
      _handleConnectionFailure('Connection timeout');
      return false;
    } on SocketException catch (e) {
      logger.e('🌐 Network error: $e');
      _connectionState = ConnectionState.failed;
      _handleConnectionFailure('Network error: ${e.message}');
      return false;
    } on WebSocketException catch (e) {
      logger.e('🔌 WebSocket error: $e');
      _connectionState = ConnectionState.failed;
      _handleConnectionFailure('WebSocket error: ${e.message}');
      return false;
    } catch (e) {
      logger.e('❌ Unexpected connection error: $e');
      _connectionState = ConnectionState.failed;
      _handleConnectionFailure('Unexpected error: $e');
      return false;
    } finally {
      _connectionTimeoutTimer?.cancel();
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

  void _handleConnectionFailure(String reason) {
    logger.e('Connection failed: $reason');
    if (_shouldAutoReconnect) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectAttempts++;
    final Duration delay = Duration(seconds: math.min(30, math.pow(2, _reconnectAttempts).toInt()));
    logger.i('🔄 Scheduling reconnect attempt $_reconnectAttempts in ${delay.inSeconds}s');

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (_lastUrl != null) {
        logger.i('🔄 Attempting reconnect $_reconnectAttempts');
        // This would need to be implemented based on how reconnection should work
      }
    });
  }

  void _startConnectionHealthMonitoring() {
    // Placeholder for connection health monitoring
    logger.d('🔍 Starting connection health monitoring');
  }

  Future<void> _processMessageQueue() async {
    // Placeholder for processing message queue
    logger.d('📤 Processing message queue');
  }

  Future<void> _disconnect({bool disableAutoReconnect = true}) async {
    if (disableAutoReconnect) {
      _shouldAutoReconnect = false;
    }

    _connectionTimeoutTimer?.cancel();
    _reconnectTimer?.cancel();

    if (_channel != null) {
      await _channel!.sink.close();
      _channel = null;
    }

    if (_socket != null) {
      _socket!.close();
      _socket = null;
    }

    _connectionState = ConnectionState.disconnected;
    _isConnected = false;
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

  /// For test only.
  Future<WebSocket> _connectForBadCertificate(String url, WebSocketSettings webSocketSettings) async {
    try {
      final math.Random r = math.Random();
      String key = base64.encode(List<int>.generate(16, (_) => r.nextInt(255)));
      SecurityContext securityContext = SecurityContext();
      HttpClient client = HttpClient(context: securityContext);

      if (webSocketSettings.userAgent != null) {
        client.userAgent = webSocketSettings.userAgent;
      }

      client.badCertificateCallback = (X509Certificate cert, String host, int port) {
        logger.w('Allow self-signed certificate => $host:$port. ');
        return true;
      };

      Uri parsed_uri = Uri.parse(url);
      Uri uri = parsed_uri.replace(scheme: parsed_uri.scheme == 'wss' ? 'https' : 'http');

      HttpClientRequest request = await client.getUrl(uri); // form the correct url here
      request.headers.add('Connection', 'Upgrade', preserveHeaderCase: true);
      request.headers.add('Upgrade', 'websocket', preserveHeaderCase: true);
      request.headers.add('Sec-WebSocket-Version', '13', preserveHeaderCase: true); // insert the correct version here
      request.headers.add('Sec-WebSocket-Key', key.toLowerCase(), preserveHeaderCase: true);
      request.headers.add('Sec-WebSocket-Protocol', 'sip', preserveHeaderCase: true);

      webSocketSettings.extraHeaders.forEach((String key, dynamic value) {
        request.headers.add(key, value, preserveHeaderCase: true);
      });

      HttpClientResponse response = await request.close();
      Socket socket = await response.detachSocket();
      WebSocket webSocket = WebSocket.fromUpgradedSocket(
        socket,
        protocol: 'sip',
        serverSide: false,
      );

      return webSocket;
    } catch (e) {
      logger.e('error $e');
      rethrow;
    }
  }
}
