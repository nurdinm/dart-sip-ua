import 'dart:async';
import 'dart:io';

void main() async {
  print('Testing WebSocket close issue...');
  
  try {
    // Connect to a WebSocket echo server
    final webSocket = await WebSocket.connect('wss://echo.websocket.org/');
    print('WebSocket connected successfully');
    
    // Set up listeners
    webSocket.listen(
      (data) {
        print('Received: $data');
      },
      onDone: () {
        print('WebSocket closed. Code: ${webSocket.closeCode}, Reason: ${webSocket.closeReason}');
      },
      onError: (error) {
        print('WebSocket error: $error');
      },
    );
    
    // Send a SIP REGISTER message
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
    webSocket.add(registerMessage);
    
    // Wait for response or closure
    await Future.delayed(Duration(seconds: 10));
    
    if (webSocket.readyState == WebSocket.open) {
      print('WebSocket is still open');
      webSocket.close();
    } else {
      print('WebSocket closed unexpectedly');
    }
    
  } catch (e) {
    print('Error: $e');
  }
  
  print('Test completed');
}