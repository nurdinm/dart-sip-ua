import 'dart:async';

import 'package:test/test.dart';
import 'package:sip_ua/src/socket_transport.dart';
import 'package:sip_ua/src/transports/socket_interface.dart';
import 'package:sip_ua/src/event_manager/events.dart';

/// Simple mock WebSocket for testing
class TestSocket extends SIPUASocketInterface {
  TestSocket();

  bool _connected = false;
  final List<String> _sentMessages = [];
  String _viaTransport = 'WS';
  
  @override
  String get via_transport => _viaTransport;

  @override
  set via_transport(String value) {
    _viaTransport = value;
  }

  @override
  String? get url => 'ws://test.example.com';

  @override
  String? get sip_uri => 'sip:test.example.com';

  @override
  int? get weight => 1;

  @override
  void Function()? onconnect;

  @override
  void Function(SIPUASocketInterface socket, bool error, int? closeCode, String? reason)? ondisconnect;

  @override
  void Function(dynamic data)? ondata;

  @override
  void connect() {
    Timer(Duration(milliseconds: 10), () {
      _connected = true;
      onconnect?.call();
    });
  }

  @override
  void disconnect() {
    _connected = false;
    ondisconnect?.call(this, false, 1000, 'Normal closure');
  }

  @override
  bool send(dynamic data) {
    if (!_connected) return false;
    _sentMessages.add(data.toString());
    
    // Simulate ping/pong responses
    if (data == '{"message":"ping","data":[]}') {
      Timer(Duration(milliseconds: 5), () {
        ondata?.call('{"message":"pong","data":[]}');
      });
    }
    
    return true;
  }

  @override
  bool isConnected() => _connected;

  @override
  bool isConnecting() => false;

  List<String> get sentMessages => List.unmodifiable(_sentMessages);
  
  void simulateIncomingPing() {
    if (_connected) {
      ondata?.call('{"message":"ping","data":[]}');
    }
  }
  
  void simulateMessage(String message) {
    if (_connected) {
      ondata?.call(message);
    }
  }
}

void main() {
  group('Socket Transport Ping/Pong Tests', () {
    late TestSocket testSocket;
    late SocketTransport transport;

    setUp(() {
      testSocket = TestSocket();
      transport = SocketTransport([testSocket]);
    });

    test('should handle ping/pong messages', () async {
      Completer<void> completer = Completer<void>();
      bool pongReceived = false;
      
      // Initialize required callbacks
      transport.onconnecting = (SIPUASocketInterface? socket, int? attempts) {};
      transport.ondisconnect = (SIPUASocketInterface? socket, ErrorCause cause) {};
      
      transport.onconnect = (SocketTransport t) {
        // Send a ping
        transport.socket.send('{"message":"ping","data":[]}');
      };
      
      transport.ondata = (SocketTransport t, String data) {
        if (data == '{"message":"pong","data":[]}') {
          pongReceived = true;
          completer.complete();
        }
      };
      
      transport.connect();
      await completer.future;
      
      expect(pongReceived, isTrue);
      expect(testSocket.sentMessages, contains('{"message":"ping","data":[]}'));
    });

    test('should respond to incoming ping with pong', () async {
      Completer<void> completer = Completer<void>();
      
      // Initialize required callbacks
      transport.onconnecting = (SIPUASocketInterface? socket, int? attempts) {};
      transport.ondisconnect = (SIPUASocketInterface? socket, ErrorCause cause) {};
      transport.onconnect = (SocketTransport transport) {};
      transport.ondata = (SocketTransport transport, String messageData) {};
      
      transport.onconnect = (SocketTransport t) {
        // Simulate incoming ping
        testSocket.simulateIncomingPing();
        
        Timer(Duration(milliseconds: 20), () {
          // Check if pong was sent in response
          expect(testSocket.sentMessages, contains('{"message":"pong","data":[]}'));
          completer.complete();
        });
      };
      
      transport.connect();
      await completer.future;
    });

    test('should track connection health', () async {
      Completer<void> completer = Completer<void>();
      
      // Initialize required callbacks
      transport.onconnecting = (SIPUASocketInterface? socket, int? attempts) {};
      transport.ondisconnect = (SIPUASocketInterface? socket, ErrorCause cause) {};
      transport.onconnect = (SocketTransport transport) {};
      transport.ondata = (SocketTransport transport, String messageData) {};
      
      transport.onconnect = (SocketTransport t) {
        // Initially no messages received
        expect(transport.lastMessageReceived, isNull);
        
        // Simulate incoming message
        testSocket.simulateMessage('INVITE sip:test@example.com SIP/2.0');
        
        Timer(Duration(milliseconds: 20), () {
          // Check if last message time was updated
          expect(transport.lastMessageReceived, isNotNull);
          expect(transport.isConnectionHealthy(), isTrue);
          completer.complete();
        });
      };
      
      transport.connect();
      await completer.future;
    });

    test('should manage health check failures', () async {
      Completer<void> completer = Completer<void>();
      
      // Initialize required callbacks
      transport.onconnecting = (SIPUASocketInterface? socket, int? attempts) {};
      transport.ondisconnect = (SIPUASocketInterface? socket, ErrorCause cause) {};
      transport.onconnect = (SocketTransport transport) {};
      transport.ondata = (SocketTransport transport, String messageData) {};
      
      transport.onconnect = (SocketTransport t) {
        expect(transport.consecutiveHealthChecks, equals(0));
        
        transport.incrementHealthCheckFailures();
        expect(transport.consecutiveHealthChecks, equals(1));
        
        transport.incrementHealthCheckFailures();
        expect(transport.consecutiveHealthChecks, equals(2));
        
        transport.resetHealthCheckFailures();
        expect(transport.consecutiveHealthChecks, equals(0));
        
        completer.complete();
      };
      
      transport.connect();
      await completer.future;
    });

    test('should send ping messages', () async {
      Completer<void> completer = Completer<void>();
      
      // Initialize required callbacks
      transport.onconnecting = (SIPUASocketInterface? socket, int? attempts) {};
      transport.ondisconnect = (SIPUASocketInterface? socket, ErrorCause cause) {};
      transport.onconnect = (SocketTransport transport) {};
      transport.ondata = (SocketTransport transport, String messageData) {};
      
      transport.onconnect = (SocketTransport t) {
        transport.sendPing();
        
        Timer(Duration(milliseconds: 20), () {
          expect(testSocket.sentMessages, contains('{"message":"ping","data":[]}'));
          completer.complete();
        });
      };
      
      transport.connect();
      await completer.future;
    });
  });
}