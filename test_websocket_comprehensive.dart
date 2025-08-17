import 'dart:async';
import 'dart:io';

void main() async {
  print('🔍 Comprehensive WebSocket SIP Connection Test');
  print('=' * 50);
  
  try {
    // Test with proper SIP WebSocket headers
    final headers = {
      'Origin': 'https://voip1-yanpol.polri.go.id',
      'User-Agent': 'Dart SIP UA Client v1.0.0',
      'Sec-WebSocket-Protocol': 'sip'
    };
    
    print('📡 Connecting to WebSocket with SIP protocol...');
    print('🔗 URL: wss://voip1-yanpol.polri.go.id:8443');
    print('📋 Headers: $headers');
    
    final webSocket = await WebSocket.connect(
      'wss://voip1-yanpol.polri.go.id:8443',
      protocols: ['sip'],
      headers: headers,
    ).timeout(
      Duration(seconds: 30),
      onTimeout: () {
        print('❌ Connection timeout after 30 seconds');
        throw TimeoutException('WebSocket connection timeout', Duration(seconds: 30));
      },
    );
    
    print('✅ WebSocket connected successfully!');
    print('🔌 Protocol: ${webSocket.protocol}');
    print('📊 Ready State: ${webSocket.readyState}');
    
    final connectionTime = DateTime.now();
    bool messageReceived = false;
    bool connectionClosed = false;
    
    // Set up listeners
    webSocket.listen(
      (data) {
        messageReceived = true;
        print('📨 Received: ${data.toString().length > 100 ? data.toString().substring(0, 100) + "..." : data.toString()}');
      },
      onDone: () {
        connectionClosed = true;
        final duration = DateTime.now().difference(connectionTime);
        print('🔌 WebSocket closed after ${duration.inMilliseconds}ms');
        print('📊 Close Code: ${webSocket.closeCode}');
        print('📝 Close Reason: ${webSocket.closeReason}');
      },
      onError: (error) {
        print('❌ WebSocket error: $error');
        print('🔍 Error type: ${error.runtimeType}');
      },
    );
    
    // Wait a moment for connection to stabilize
    await Future.delayed(Duration(milliseconds: 200));
    
    if (webSocket.readyState == WebSocket.open) {
      print('📤 Sending SIP REGISTER message...');
      
      final registerMessage = '''
REGISTER sip:voip1-yanpol.polri.go.id SIP/2.0
Via: SIP/2.0/WSS test.invalid;branch=z9hG4bKtest123
Max-Forwards: 69
To: <sip:test@voip1-yanpol.polri.go.id>
From: "test" <sip:test@voip1-yanpol.polri.go.id>;tag=test123
Call-ID: test-call-id-123
CSeq: 1 REGISTER
Contact: <sip:test@test.invalid;transport=wss>;expires=600
Expires: 600
User-Agent: Dart SIP UA Client v1.0.0
Content-Length: 0

''';
      
      webSocket.add(registerMessage);
      print('✅ REGISTER message sent');
      
      // Wait for response or closure
      print('⏳ Waiting for server response...');
      
      for (int i = 0; i < 100; i++) {
        await Future.delayed(Duration(milliseconds: 100));
        
        if (connectionClosed) {
          print('❌ Connection closed unexpectedly');
          break;
        }
        
        if (messageReceived) {
          print('✅ Received response from server');
          break;
        }
        
        if (i % 10 == 0) {
          print('⏱️  Still waiting... ${i/10}s elapsed');
        }
      }
      
      if (webSocket.readyState == WebSocket.open) {
        print('✅ WebSocket is still open after REGISTER');
        webSocket.close(1000, 'Test completed');
      }
    } else {
      print('❌ WebSocket not in open state');
    }
    
  } catch (e, stackTrace) {
    print('❌ Error during test: $e');
    print('📚 Stack trace: $stackTrace');
  }
  
  print('\n🏁 Test completed');
}