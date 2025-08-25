import 'dart:async';
import 'dart:html';
import 'dart:js_util' as JSUtils;

import 'package:sip_ua/src/sip_ua_helper.dart';
import '../logger.dart';
import '../timers.dart';

typedef OnMessageCallback = void Function(dynamic msg);
typedef OnCloseCallback = void Function(int? code, String? reason);
typedef OnOpenCallback = void Function();

class SIPUAWebSocketImpl {
  SIPUAWebSocketImpl(this._url, this.messageDelay);

  final String _url;
  WebSocket? _socket;
  OnOpenCallback? onOpen;
  OnMessageCallback? onMessage;
  OnCloseCallback? onClose;
  final int messageDelay;

  // Ping/Pong keepalive management for web
  Timer? _pingTimer;
  Timer? _pongTimeoutTimer;
  int _consecutivePingFailures = 0;
  bool _waitingForPong = false;
  WebSocketSettings? _webSocketSettings;
  DateTime? _lastPingTime;
  static const String _pingMessage = '__SIP_UA_PING__';
  static const String _pongMessage = '__SIP_UA_PONG__';

  void connect(
      {Iterable<String>? protocols,
      required WebSocketSettings webSocketSettings}) async {
    logger.i('connect $_url, ${webSocketSettings.extraHeaders}, $protocols');
    
    // Store WebSocket settings for ping/pong configuration
    _webSocketSettings = webSocketSettings;
    
    try {
      _socket = WebSocket(_url, 'sip');
      _socket!.onOpen.listen((Event e) {
        onOpen?.call();
        // Start ping/pong keepalive mechanism after connection
        _startPingPong();
      });

      _socket!.onMessage.listen((MessageEvent e) async {
        String message;
        if (e.data is Blob) {
          dynamic arrayBuffer = await JSUtils.promiseToFuture(
              JSUtils.callMethod(e.data, 'arrayBuffer', <Object>[]));
          message = String.fromCharCodes(arrayBuffer.asUint8List());
        } else {
          message = e.data.toString();
        }
        
        // Handle ping/pong messages
        _handleIncomingMessage(message);
      });

      _socket!.onClose.listen((CloseEvent e) {
        _stopPingPong();
        onClose?.call(e.code, e.reason);
      });
    } catch (e) {
      onClose?.call(0, e.toString());
    }
  }

  void send(dynamic data) {
    if (_socket != null && _socket!.readyState == WebSocket.OPEN) {
      _socket!.send(data);
      logger.d('send: \n\n$data');
    } else {
      logger.e('WebSocket not connected, message $data not sent');
    }
  }

  bool isConnecting() {
    return _socket != null && _socket!.readyState == WebSocket.CONNECTING;
  }

  void close() {
    _stopPingPong();
    _socket!.close();
  }

  // Ping/Pong keepalive methods for web implementation
  void _handleIncomingMessage(String message) {
    if (message == _pingMessage) {
      // Respond to ping with pong
      _sendPong();
    } else if (message == _pongMessage) {
      // Handle pong response
      _handlePongReceived();
    } else {
      // Regular SIP message
      onMessage?.call(message);
    }
  }

  void _startPingPong() {
    if (_webSocketSettings?.enablePingPong != true) {
      return;
    }

    final pingInterval = Duration(
        milliseconds: _webSocketSettings?.pingInterval ?? 30000);

    _pingTimer = setInterval(() {
       _sendPing();
     }, pingInterval.inMilliseconds);
  }

  void _stopPingPong() {
    _pingTimer?.cancel();
    _pongTimeoutTimer?.cancel();
    _pingTimer = null;
    _pongTimeoutTimer = null;
    _waitingForPong = false;
    _consecutivePingFailures = 0;
  }

  void _sendPing() {
    if (_waitingForPong) {
      _handlePingTimeout();
      return;
    }

    if (_socket != null && _socket!.readyState == WebSocket.OPEN) {
      _socket!.send(_pingMessage);
      _waitingForPong = true;
      _lastPingTime = DateTime.now();

      // Set timeout for pong response
      final pongTimeout = Duration(
          milliseconds: _webSocketSettings?.pongTimeout ?? 5000);
      _pongTimeoutTimer = setTimeout(() {
         _handlePingTimeout();
       }, pongTimeout.inMilliseconds);
    }
  }

  void _sendPong() {
    if (_socket != null && _socket!.readyState == WebSocket.OPEN) {
      _socket!.send(_pongMessage);
    }
  }

  void _handlePongReceived() {
    _waitingForPong = false;
    _consecutivePingFailures = 0;
    _pongTimeoutTimer?.cancel();
    _pongTimeoutTimer = null;
  }

  void _handlePingTimeout() {
    _waitingForPong = false;
    _consecutivePingFailures++;
    _pongTimeoutTimer?.cancel();
    _pongTimeoutTimer = null;

    final maxFailures = _webSocketSettings?.maxPingFailures ?? 3;
    if (_consecutivePingFailures >= maxFailures) {
      logger.w('WebSocket ping timeout after $maxFailures failures, reconnecting...');
      if (_webSocketSettings?.autoReconnectOnPingTimeout == true) {
        _reconnectOnPingTimeout();
      } else {
        close();
      }
    }
  }

  void _reconnectOnPingTimeout() {
    logger.i('Attempting to reconnect due to ping timeout...');
    close();
    // Note: Actual reconnection logic would be handled by the upper layer
    // This just closes the connection to trigger reconnection
  }
}
