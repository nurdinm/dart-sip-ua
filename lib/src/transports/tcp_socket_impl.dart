import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../logger.dart';
import '../sip_ua_helper.dart';

typedef OnMessageCallback = void Function(dynamic msg);
typedef OnCloseCallback = void Function(int? code, String? reason);
typedef OnOpenCallback = void Function();

class SIPUATcpSocketImpl {
  SIPUATcpSocketImpl(this.messageDelay, this._host, this._port);

  final String _host;
  final String _port;

  Socket? _socket;
  OnOpenCallback? onOpen;
  OnMessageCallback? onData;
  OnCloseCallback? onClose;
  final int messageDelay;

  void connect(
      {Iterable<String>? protocols,
      required TcpSocketSettings tcpSocketSettings}) async {
    handleQueue();
    logger.i('connect $_host:$_port with timeout ${tcpSocketSettings.connectionTimeout}s (TLS: ${tcpSocketSettings.useTLS})');
    try {
      if (tcpSocketSettings.useTLS) {
        // Use TLS/SSL connection
        logger.i('Establishing TLS connection to $_host:$_port');
        _socket = await SecureSocket.connect(
          _host,
          int.parse(_port),
          onBadCertificate: tcpSocketSettings.allowBadCertificate ? (X509Certificate cert) {
            logger.w('⚠️ SSL Certificate warning for $_host:$_port');
            logger.w('⚠️ Certificate subject: ${cert.subject}');
            logger.w('⚠️ Certificate issuer: ${cert.issuer}');
            logger.w('⚠️ Allowing connection (allowBadCertificate=true)');
            return true;
          } : null,
        ).timeout(
          Duration(seconds: tcpSocketSettings.connectionTimeout),
          onTimeout: () {
            logger.e('TLS connection timeout after ${tcpSocketSettings.connectionTimeout} seconds');
            throw TimeoutException('TLS connection timeout', Duration(seconds: tcpSocketSettings.connectionTimeout));
          },
        );
      } else {
        // Use plain TCP connection
        logger.i('Establishing plain TCP connection to $_host:$_port');
        _socket = await Socket.connect(
          _host,
          int.parse(_port),
        ).timeout(
          Duration(seconds: tcpSocketSettings.connectionTimeout),
          onTimeout: () {
            logger.e('TCP connection timeout after ${tcpSocketSettings.connectionTimeout} seconds');
            throw TimeoutException('TCP connection timeout', Duration(seconds: tcpSocketSettings.connectionTimeout));
          },
        );
      }

      logger.i('TCP socket connected successfully to $_host:$_port');
      onOpen?.call();

      _socket!.listen((dynamic data) {
        onData?.call(data);
      }, onDone: () {
        logger.d('TCP socket connection closed');
        onClose?.call(1000, 'Connection closed normally');
      }, onError: (error) {
        logger.e('TCP socket error: $error');
        onClose?.call(500, error.toString());
      });
    } on TimeoutException catch (e) {
      logger.e('TCP connection timeout: $e');
      onClose?.call(408, 'Connection timeout: ${e.message}');
    } catch (e) {
      logger.e('TCP connection error: $e');
      onClose?.call(500, e.toString());
    }
  }

  final StreamController<dynamic> queue = StreamController<dynamic>.broadcast();
  void handleQueue() async {
    queue.stream.asyncMap((dynamic event) async {
      await Future<void>.delayed(Duration(milliseconds: messageDelay));
      return event;
    }).listen((dynamic event) async {
      _socket!.add(event.codeUnits);
      logger.d('send: \n\n$event');
    });
  }

  void send(dynamic data) async {
    if (_socket != null) {
      queue.add(data);
    }
  }

  void close() {
    _socket!.close();
  }
}
