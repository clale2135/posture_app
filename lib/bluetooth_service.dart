import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;

class BluetoothService {
  fbp.BluetoothDevice? _device;
  fbp.BluetoothCharacteristic? _characteristic; // TX (notify)
  fbp.BluetoothCharacteristic? _rxCharacteristic; // RX (write)
  StreamSubscription<List<int>>? _subscription;
  
  // Buffer for incomplete lines
  String _buffer = '';
  
  Function(Map<String, dynamic>)? onDataReceived;
  Function(bool)? onConnectionChanged;
  Function(String)? onCalibrationMessage; // Callback for calibration status messages
  
  // Nordic UART Service UUIDs
  static const String nordicUartServiceUUID = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
  static const String nordicUartRXCharUUID = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E'; // Write
  static const String nordicUartTXCharUUID = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E'; // Notify

  Future<void> connectToDevice(String deviceName) async {
    try {
      // Check if Bluetooth is available
      if (await fbp.FlutterBluePlus.isSupported == false) {
        throw Exception('Bluetooth not supported');
      }

      // Turn on Bluetooth if off
      if (await fbp.FlutterBluePlus.adapterState.first == fbp.BluetoothAdapterState.off) {
        await fbp.FlutterBluePlus.turnOn();
      }

      // Start scanning
      await fbp.FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

      // Listen for scan results
      await for (List<fbp.ScanResult> results in fbp.FlutterBluePlus.scanResults) {
        for (fbp.ScanResult result in results) {
          if (result.device.platformName == deviceName || 
              result.device.advName == deviceName) {
            await fbp.FlutterBluePlus.stopScan();
            _device = result.device;
            break;
          }
        }
        if (_device != null) break;
      }

      if (_device == null) {
        throw Exception('Device $deviceName not found');
      }

      // Connect to device
      await _device!.connect(timeout: const Duration(seconds: 15));
      onConnectionChanged?.call(true);

      // Discover services
      List<fbp.BluetoothService> services = await _device!.discoverServices();

      // Find Nordic UART Service TX characteristic (for notifications)
      fbp.BluetoothCharacteristic? txChar;
      fbp.BluetoothCharacteristic? rxChar;
      
      for (fbp.BluetoothService service in services) {
        if (service.uuid.toString().toUpperCase() == nordicUartServiceUUID.toUpperCase()) {
          for (fbp.BluetoothCharacteristic characteristic in service.characteristics) {
            String charUUID = characteristic.uuid.toString().toUpperCase();
            if (charUUID == nordicUartTXCharUUID.toUpperCase()) {
              txChar = characteristic; // Notify characteristic
            } else if (charUUID == nordicUartRXCharUUID.toUpperCase()) {
              rxChar = characteristic; // Write characteristic
            }
          }
          break;
        }
      }

      // Fallback: if Nordic UART not found, use first notify characteristic
      if (txChar == null) {
        for (fbp.BluetoothService service in services) {
          for (fbp.BluetoothCharacteristic characteristic in service.characteristics) {
            if (characteristic.properties.notify) {
              txChar = characteristic;
              break;
            }
          }
          if (txChar != null) break;
        }
      }

      if (txChar == null) {
        throw Exception('No suitable characteristic found (looking for Nordic UART TX)');
      }

      _characteristic = txChar;
      _rxCharacteristic = rxChar; // Store RX char for writing commands

      // Subscribe to notifications
      await _characteristic!.setNotifyValue(true);
      _subscription = _characteristic!.onValueReceived.listen((value) {
        _parseData(value);
      });
    } catch (e) {
      await disconnect();
      rethrow;
    }
  }

  void _parseData(List<int> data) {
    try {
      // Convert bytes to string
      String text = utf8.decode(data);
      _buffer += text;
      
      // Process complete lines (device sends lines ending with \n)
      while (_buffer.contains('\n')) {
        int newlineIndex = _buffer.indexOf('\n');
        String line = _buffer.substring(0, newlineIndex).trim();
        _buffer = _buffer.substring(newlineIndex + 1);
        
        if (line.isNotEmpty) {
          _parseLine(line);
        }
      }
    } catch (e) {
      // Handle parsing errors silently
    }
  }
  
  void _parseLine(String line) {
    try {
      // Check for calibration messages first
      if (line.startsWith('CAL:')) {
        onCalibrationMessage?.call(line);
        return;
      }
      
      // Parse format: "posture=BAD ax=0.123 ay=0.456 az=0.789 dGood=0.123 dBad=0.456"
      Map<String, String> parts = {};
      
      // Split by spaces and parse key=value pairs
      List<String> tokens = line.split(' ');
      for (String token in tokens) {
        if (token.contains('=')) {
          List<String> kv = token.split('=');
          if (kv.length == 2) {
            parts[kv[0]] = kv[1];
          }
        }
      }
      
      // Extract posture status
      String? postureStr = parts['posture'];
      bool isPostureGood = postureStr?.toUpperCase() == 'GOOD';
      
      // Extract motion values (ax, ay, az)
      double? ax = double.tryParse(parts['ax'] ?? '0');
      double? ay = double.tryParse(parts['ay'] ?? '0');
      double? az = double.tryParse(parts['az'] ?? '0');
      
      // Send parsed data
      onDataReceived?.call({
        'posture': isPostureGood ? 'GOOD' : 'BAD',
        'motion': {
          'x': ax ?? 0.0,
          'y': ay ?? 0.0,
          'z': az ?? 0.0,
        },
      });
    } catch (e) {
      // Handle parsing errors
    }
  }

  Future<void> reset() async {
    if (_characteristic == null || !_characteristic!.properties.write) {
      throw Exception('Device not connected or write not available');
    }
    
    // Send reset command (adjust command format based on your device)
    // Example: sending byte 0x02 for reset
    await _characteristic!.write([0x02], withoutResponse: false);
  }

  /// Send a raw string command (newline terminated)
  Future<void> _sendRawCommand(String command) async {
    if (_device == null) {
      throw Exception('Device not connected');
    }
    
    // Use stored RX characteristic if available
    fbp.BluetoothCharacteristic? writeChar = _rxCharacteristic;
    
    // If RX char not available, try TX char if it supports write
    if (writeChar == null && _characteristic != null && _characteristic!.properties.write) {
      writeChar = _characteristic;
    }
    
    if (writeChar == null || !writeChar.properties.write) {
      throw Exception('No writable characteristic found');
    }
    
    // Ensure command ends with newline
    String cmd = command.endsWith('\n') ? command : '$command\n';
    await writeChar.write(cmd.codeUnits, withoutResponse: false);
  }

  /// Send calibration command: "CAL=GOOD\n"
  Future<void> sendCalGood() async {
    await _sendRawCommand('CAL=GOOD');
  }

  /// Send calibration command: "CAL=BAD\n"
  Future<void> sendCalBad() async {
    await _sendRawCommand('CAL=BAD');
  }

  /// Set LED blink mode: "LED=1\n" or "LED=0\n"
  Future<void> setLedBlink(bool on) async {
    await _sendRawCommand('LED=${on ? 1 : 0}');
  }

  /// Send a command to the device (e.g., LED blink) - legacy support
  Future<void> sendCommand(Map<String, dynamic> command) async {
    if (command.containsKey('led')) {
      await setLedBlink(command['led'] == 1);
    } else if (command.containsKey('start')) {
      await _sendRawCommand('START=${command['start']}');
    } else {
      // Generic JSON command format
      String commandJson = '${jsonEncode(command)}\n';
      await _sendRawCommand(commandJson.trim());
    }
  }
  
  Future<void> start() async {
    await _sendRawCommand('START=1');
  }

  Future<void> disconnect() async {
    await _subscription?.cancel();
    _subscription = null;
    
    if (_device != null) {
      await _device!.disconnect();
      _device = null;
    }
    
    _characteristic = null;
    _rxCharacteristic = null;
    onConnectionChanged?.call(false);
  }
}

