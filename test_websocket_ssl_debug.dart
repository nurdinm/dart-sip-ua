import 'dart:async';
import 'dart:io';

void main() async {
  print('🔍 WebSocket SSL/TLS Debug Test');
  print('=' * 50);
  
  try {
    // Create HTTP client with custom certificate handling
    final httpClient = HttpClient();
    httpClient.badCertificateCallback = (X509Certificate cert, String host, int port) {
      print('🔒 Certificate Info:');
      print('   Subject: ${cert.subject}');
      print('   Issuer: ${cert.issuer}');
      print('   Valid from: ${cert.startValidity}');
      print('   Valid to: ${cert.endValidity}');
      print('   Host: $host:$port');
      print('   ⚠️  Accepting invalid certificate for testing');
      return true; // Accept all certificates for testing
    };
    
    // Test basic HTTPS connection first
    print('🌐 Testing HTTPS connection to server...');
    try {
      final request = await httpClient.getUrl(Uri.parse('https://voip1-yanpol.polri.go.id:8443'));
      request.headers.set('User-Agent', 'Dart SIP UA Test Client');
      final response = await request.close();
      print('✅ HTTPS connection successful');
      print('📊 Status: ${response.statusCode}');
      print('📋 Headers: ${response.headers}');
      await response.drain();
    } catch (e) {
      print('❌ HTTPS connection failed: $e');
    }
    
    print('\n📡 Testing WebSocket connection with SSL bypass...');
    
    final headers = {
      'Origin': 'https://voip1-yanpol.polri.go.id',
      'User-Agent': 'Dart SIP UA Client v1.0.0',
    };
    
    print('🔗 URL: wss://voip1-yanpol.polri.go.id:8443');
    print('📋 Headers: $headers');
    
    final webSocket = await WebSocket.connect(
      'wss://voip1-yanpol.polri.go.id:8443',
      protocols: ['sip'],
      headers: headers,
      customClient: httpClient,
    ).timeout(
      Duration(seconds: 15),
      onTimeout: () {
        print('❌ WebSocket connection timeout after 15 seconds');
        throw TimeoutException('WebSocket connection timeout', Duration(seconds: 15));
      },
    );
    
    print('✅ WebSocket connected successfully!');
    print('🔌 Protocol: ${webSocket.protocol}');
    print('📊 Ready State: ${webSocket.readyState}');
    
    final connectionTime = DateTime.now();
    bool connectionClosed = false;
    
    // Set up listeners
    webSocket.listen(
      (data) {
        print('📨 Received: ${data.toString().length > 200 ? data.toString().substring(0, 200) + "..." : data.toString()}');
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
    
    // Wait for connection to stabilize
    await Future.delayed(Duration(milliseconds: 500));
    
    if (webSocket.readyState == WebSocket.open) {
      print('📤 Sending simple SIP OPTIONS message...');
      
      final optionsMessage = '''
OPTIONS sip:voip1-yanpol.polri.go.id SIP/2.0
Via: SIP/2.0/WSS test.invalid;branch=z9hG4bKtest123
Max-Forwards: 69
To: <sip:voip1-yanpol.polri.go.id>
From: "test" <sip:test@voip1-yanpol.polri.go.id>;tag=test123
Call-ID: test-options-123
CSeq: 1 OPTIONS
User-Agent: Dart SIP UA Client v1.0.0
Content-Length: 0

''';
      
      webSocket.add(optionsMessage);
      print('✅ OPTIONS message sent');
      
      // Wait for response
      print('⏳ Waiting for server response...');
      
      for (int i = 0; i < 50; i++) {
        await Future.delayed(Duration(milliseconds: 200));
        
        if (connectionClosed) {
          print('❌ Connection closed unexpectedly');
          break;
        }
        
        if (i % 5 == 0) {
          print('⏱️  Still waiting... ${(i*200)/1000}s elapsed');
        }
      }
      
      if (webSocket.readyState == WebSocket.open) {
        print('✅ WebSocket is still open after OPTIONS');
        webSocket.close(1000, 'Test completed');
      }
    } else {
      print('❌ WebSocket not in open state');
    }
    
    httpClient.close();
    
  } catch (e, stackTrace) {
    print('❌ Error during test: $e');
    print('📚 Stack trace: $stackTrace');
  }
  
  print('\n🏁 SSL Debug test completed');
}