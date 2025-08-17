import 'dart:async';
import 'package:test/test.dart';
import 'package:sip_ua/src/transports/web_socket.dart';
import 'package:sip_ua/src/sip_ua_helper.dart';
import 'package:sip_ua/src/transports/socket_interface.dart';

void main() {
  group('WebSocket Close Debug Tests', () {
    test('should handle WebSocket close after REGISTER message', () async {
      final completer = Completer<void>();
      
      // Create WebSocket with debug settings
      final webSocketSettings = WebSocketSettings()
        ..enablePingPong = true
        ..pingInterval = 30
        ..pongTimeout = 10
        ..maxPingFailures = 3
        ..autoReconnectOnPingTimeout = false; // Disable auto-reconnect for testing
      
      final webSocket = SIPUAWebSocket(
        'wss://echo.websocket.org/', // Use a test WebSocket server
        messageDelay: 0,
        webSocketSettings: webSocketSettings,
      );
      
      bool connectionEstablished = false;
      bool messageReceived = false;
      
      webSocket.onconnect = () {
        print('WebSocket connected successfully');
        connectionEstablished = true;
        
        // Simulate sending a REGISTER message
        final registerMessage = '''
REGISTER sip:test.example.com SIP/2.0
Via: SIP/2.0/WSS test.invalid;branch=z9hG4bKtest
Max-Forwards: 69
To: <sip:test@test.example.com>
From: "test" <sip:test@test.example.com>;tag=test
Call-ID: test-call-id
CSeq: 1 REGISTER
Contact: <sip:test@test.invalid;transport=wss>;expires=600
Expires: 600
Content-Length: 0

''';
        
        print('Sending REGISTER message...');
        webSocket.send(registerMessage);
      };
      
      webSocket.ondata = (dynamic data) {
        print('Received data: \$data');
        messageReceived = true;
      };
      
      webSocket.ondisconnect = (SIPUASocketInterface socket, bool error, int? closeCode, String? reason) {
        print('WebSocket disconnected - Error: \$error, Code: \$closeCode, Reason: \$reason');
        
        // Complete the test
        if (connectionEstablished) {
          completer.complete();
        } else {
          completer.completeError('Connection failed');
        }
      };
      
      // Connect to WebSocket
      webSocket.connect();
      
      // Wait for test completion with timeout
      await completer.future.timeout(
        Duration(seconds: 60),
        onTimeout: () {
          print('Test timed out');
          webSocket.disconnect();
          throw TimeoutException('Test timed out', Duration(seconds: 60));
        },
      );
      
      expect(connectionEstablished, isTrue, reason: 'WebSocket should have connected');
      print('Test completed successfully');
    });
  });
}