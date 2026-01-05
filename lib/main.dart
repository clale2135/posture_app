import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'bluetooth_service.dart';

void main() {
  runApp(const PostureApp());
}

class PostureApp extends StatelessWidget {
  const PostureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Posture Monitor',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const PostureMonitorScreen(),
    );
  }
}

class PostureMonitorScreen extends StatefulWidget {
  const PostureMonitorScreen({super.key});

  @override
  State<PostureMonitorScreen> createState() => _PostureMonitorScreenState();
}

class _PostureMonitorScreenState extends State<PostureMonitorScreen> {
  final BluetoothService _bluetoothService = BluetoothService();
  
  bool _isConnected = false;
  bool _isPostureGood = false;
  bool _isCalibrated = false;
  bool _isCalibrating = false;
  bool _calibratingGood = false; // Track which calibration step we're on
  int _calibrationSecondsRemaining = 0;
  Timer? _calibrationTimer;
  Timer? _countdownTimer;
  
  Map<String, double> _motionData = {
    'x': 0.0,
    'y': 0.0,
    'z': 0.0,
  };
  
  // Baseline data from calibration
  double _baselineAx = 0.0;
  double _baselineAy = 0.0;
  double _baselineAz = 0.0;
  List<Map<String, double>> _calibrationSamples = [];
  
  String _statusMessage = 'Not connected';
  static const double _deviationThreshold = 0.3; // Threshold for bad posture
  
  // Serial monitor data
  List<String> _serialLines = [];
  static const int _maxSerialLines = 100; // Keep last 100 lines

  @override
  void initState() {
    super.initState();
    _bluetoothService.onDataReceived = _handleDataReceived;
    _bluetoothService.onConnectionChanged = _handleConnectionChanged;
    _bluetoothService.onCalibrationMessage = _handleCalibrationMessage;
    _bluetoothService.onSerialData = _handleSerialData;
  }
  
  void _handleSerialData(String line) {
    if (!mounted) return;
    
    print('Serial monitor received: $line'); // Debug log
    
    setState(() {
      // Add timestamp to the line
      final timestamp = DateTime.now();
      final timeStr = '${timestamp.hour.toString().padLeft(2, '0')}:'
          '${timestamp.minute.toString().padLeft(2, '0')}:'
          '${timestamp.second.toString().padLeft(2, '0')}.'
          '${timestamp.millisecond.toString().padLeft(3, '0')}';
      
      _serialLines.add('[$timeStr] $line');
      
      // Keep only last N lines
      if (_serialLines.length > _maxSerialLines) {
        _serialLines.removeAt(0);
      }
    });
  }
  
  void _handleCalibrationMessage(String message) {
    if (!mounted) return;
    
    print('Calibration message received: $message'); // Debug log
    
    // Handle device calibration status messages
    if (message.contains('CAL:DONE') || message.contains('calibrated') || message.toLowerCase().contains('calibration complete')) {
      setState(() {
        _isCalibrated = true;
        _isCalibrating = false;
        _calibrationTimer?.cancel();
        _countdownTimer?.cancel();
        _calibrationSecondsRemaining = 0;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Device calibration complete!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } else if (message.contains('CAL:GOOD:START') || message.contains('CAL:BAD:START')) {
      // Device acknowledged calibration start
      print('Device acknowledged calibration: $message');
    } else if (message.toLowerCase().contains('waiting for') || message.toLowerCase().contains('not calibrated')) {
      // Device is still waiting for calibration
      setState(() {
        _isCalibrated = false;
      });
    }
  }

  void _handleDataReceived(Map<String, dynamic> data) {
    if (!mounted) return;
    
    setState(() {
      if (data.containsKey('motion')) {
        _motionData = Map<String, double>.from(data['motion']);
        
        double ax = _motionData['x'] ?? 0.0;
        double ay = _motionData['y'] ?? 0.0;
        double az = _motionData['z'] ?? 0.0;
        
        // During calibration, collect samples
        if (_isCalibrating) {
          _calibrationSamples.add({'x': ax, 'y': ay, 'z': az});
        }
      }
      
      // Use device's posture status if available (preferred)
      // Only update posture if device is calibrated
      if (data.containsKey('posture') && _isCalibrated) {
        bool newPosture = data['posture'] == 'GOOD';
        if (_isPostureGood != newPosture) {
          print('Posture changed: ${_isPostureGood ? "GOOD" : "BAD"} → ${newPosture ? "GOOD" : "BAD"}');
        }
        _isPostureGood = newPosture;
      } else if (_isCalibrated && !_isCalibrating && data.containsKey('motion')) {
        // Fallback to local calculation if device doesn't send posture
        double ax = _motionData['x'] ?? 0.0;
        double ay = _motionData['y'] ?? 0.0;
        double az = _motionData['z'] ?? 0.0;
        
        // Calculate deviation from baseline
        double deviation = sqrt(
          pow(ax - _baselineAx, 2) + 
          pow(ay - _baselineAy, 2) + 
          pow(az - _baselineAz, 2)
        );
        
        _isPostureGood = deviation < _deviationThreshold;
      }
    });
  }

  void _handleConnectionChanged(bool connected) {
    if (!mounted) return;
    setState(() {
      _isConnected = connected;
      _statusMessage = connected ? 'Connected to XIAO-Posture' : 'Not connected';
      if (connected) {
        // Add connection message to serial monitor
        final timestamp = DateTime.now();
        final timeStr = '${timestamp.hour.toString().padLeft(2, '0')}:'
            '${timestamp.minute.toString().padLeft(2, '0')}:'
            '${timestamp.second.toString().padLeft(2, '0')}.'
            '${timestamp.millisecond.toString().padLeft(3, '0')}';
        _serialLines.add('[$timeStr] Connected to XIAO-Posture');
      } else {
        _isCalibrated = false;
        _isCalibrating = false;
        _calibrationTimer?.cancel();
        _countdownTimer?.cancel();
        _calibrationSamples.clear();
        // Add disconnection message
        final timestamp = DateTime.now();
        final timeStr = '${timestamp.hour.toString().padLeft(2, '0')}:'
            '${timestamp.minute.toString().padLeft(2, '0')}:'
            '${timestamp.second.toString().padLeft(2, '0')}.'
            '${timestamp.millisecond.toString().padLeft(3, '0')}';
        _serialLines.add('[$timeStr] Disconnected');
      }
      // Keep only last N lines
      if (_serialLines.length > _maxSerialLines) {
        _serialLines.removeAt(0);
      }
    });
  }

  Future<void> _connectToDevice() async {
    try {
      await _bluetoothService.connectToDevice('XIAO-Posture');
      
      // Send start command to device after successful connection
      try {
        await _bluetoothService.start();
      } catch (e) {
        print('Warning: Failed to send start command: $e');
        // Add error to serial monitor
        final timestamp = DateTime.now();
        final timeStr = '${timestamp.hour.toString().padLeft(2, '0')}:'
            '${timestamp.minute.toString().padLeft(2, '0')}:'
            '${timestamp.second.toString().padLeft(2, '0')}.'
            '${timestamp.millisecond.toString().padLeft(3, '0')}';
        setState(() {
          _serialLines.add('[$timeStr] Warning: Failed to send start command: $e');
        });
      }
      
      setState(() {
        _statusMessage = 'Connected to XIAO-Posture';
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Connection failed: $e';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect: $e')),
        );
      }
    }
  }

  Future<void> _sendBleCommand(String cmd) async {
    if (!_isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Not connected to device')),
        );
      }
      return;
    }
    
    // Add TX line to serial monitor
    final timestamp = DateTime.now();
    final timeStr = '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}.'
        '${timestamp.millisecond.toString().padLeft(3, '0')}';
    
    setState(() {
      _serialLines.add('[$timeStr] TX → $cmd');
      if (_serialLines.length > _maxSerialLines) {
        _serialLines.removeAt(0);
      }
    });
    
    try {
      await _bluetoothService.sendBleCommand(cmd);
    } catch (e) {
      setState(() {
        _serialLines.add('[$timeStr] TX ERROR → $e');
        if (_serialLines.length > _maxSerialLines) {
          _serialLines.removeAt(0);
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send command: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _startCalibration() async {
    if (!_isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Not connected to device')),
        );
      }
      return;
    }
    
    // Start with CAL=GOOD (step 1)
    await _startCalibrationStep(true);
  }
  
  Future<void> _startCalibrationStep(bool isGood) async {
    // Send calibration command
    await _sendBleCommand(isGood ? 'CAL=GOOD' : 'CAL=BAD');
    
    setState(() {
      _isCalibrating = true;
      _calibratingGood = isGood;
      _isCalibrated = false;
      _calibrationSamples.clear();
      _calibrationSecondsRemaining = 3; // Device expects 3 seconds per step
    });
    
    // Countdown timer
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        if (_calibrationSecondsRemaining > 0) {
          _calibrationSecondsRemaining--;
        } else {
          timer.cancel();
        }
      });
    });
    
    // Wait 3 seconds (device calibration time), then move to next step or complete
    _calibrationTimer?.cancel();
    _calibrationTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      
      if (isGood) {
        // After CAL=GOOD, send CAL=BAD
        _startCalibrationStep(false);
      } else {
        // After CAL=BAD, wait for device to send CAL:DONE
        // Don't set _isCalibrated yet - wait for device confirmation
        setState(() {
          _isCalibrating = false;
          _calibrationSecondsRemaining = 0;
        });
        
        _countdownTimer?.cancel();
        
        // Calculate baseline average from collected samples
        if (_calibrationSamples.isNotEmpty) {
          double sumAx = 0.0, sumAy = 0.0, sumAz = 0.0;
          for (var sample in _calibrationSamples) {
            sumAx += sample['x'] ?? 0.0;
            sumAy += sample['y'] ?? 0.0;
            sumAz += sample['z'] ?? 0.0;
          }
          _baselineAx = sumAx / _calibrationSamples.length;
          _baselineAy = sumAy / _calibrationSamples.length;
          _baselineAz = sumAz / _calibrationSamples.length;
        }
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Calibration steps sent! Waiting for device confirmation (CAL:DONE)...'),
              backgroundColor: Colors.blue,
              duration: Duration(seconds: 5),
            ),
          );
        }
      }
    });
  }

  Future<void> _reset() async {
    try {
      await _bluetoothService.reset();
      setState(() {
        _isCalibrated = false;
        _isCalibrating = false;
        _calibrationTimer?.cancel();
        _countdownTimer?.cancel();
        _calibrationSamples.clear();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reset complete')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Reset failed: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _calibrationTimer?.cancel();
    _countdownTimer?.cancel();
    _bluetoothService.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Posture Monitor'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Connection Status
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                          color: _isConnected ? Colors.green : Colors.grey,
                          size: 32,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _statusMessage,
                          style: const TextStyle(fontSize: 16),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _isConnected ? null : _connectToDevice,
                      child: const Text('Connect to XIAO-Posture'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            // Calibration Section
            if (_isConnected) ...[
              Card(
                color: _isCalibrated ? Colors.green.shade50 : Colors.orange.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _isCalibrated ? Icons.check_circle : Icons.warning,
                            color: _isCalibrated ? Colors.green : Colors.orange,
                            size: 24,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _isCalibrated ? 'Calibrated' : 'Not Calibrated',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: _isCalibrated ? Colors.green : Colors.orange,
                            ),
                          ),
                        ],
                      ),
                      if (_isCalibrating) ...[
                        const SizedBox(height: 16),
                        Text(
                          '$_calibrationSecondsRemaining',
                          style: TextStyle(
                            fontSize: 72,
                            fontWeight: FontWeight.bold,
                            color: _calibratingGood ? Colors.green : Colors.red,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _calibratingGood 
                              ? 'Hold GOOD posture...' 
                              : 'Now SLOUCH...',
                          style: const TextStyle(fontSize: 16),
                        ),
                      ],
                      if (!_isCalibrated && !_isCalibrating) ...[
                        const SizedBox(height: 16),
                        const Text(
                          'Calibration requires 2 steps:\n1. Hold GOOD posture (3s)\n2. SLOUCH (3s)',
                          style: TextStyle(fontSize: 14),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: _isCalibrating ? null : () => _sendBleCommand('CAL=GOOD'),
                                icon: const Icon(Icons.arrow_upward),
                                label: const Text('CAL=GOOD'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: _isCalibrating ? null : () => _sendBleCommand('CAL=BAD'),
                                icon: const Icon(Icons.arrow_downward),
                                label: const Text('CAL=BAD'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          onPressed: _startCalibration,
                          icon: const Icon(Icons.timer),
                          label: const Text('Start 10s Calibration'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
            // Posture Status
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  children: [
                    const Text(
                      'Posture Status',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    if (!_isCalibrated)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                        decoration: BoxDecoration(
                          color: Colors.grey,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          'CALIBRATE FIRST',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      )
                    else if (!_isCalibrated)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                        decoration: BoxDecoration(
                          color: Colors.orange,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          'NOT CALIBRATED',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                        decoration: BoxDecoration(
                          color: _isPostureGood ? Colors.green : Colors.red,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _isPostureGood ? 'GOOD' : 'BAD',
                          style: const TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            // Serial Monitor
            if (_isConnected) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Serial Monitor',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          TextButton.icon(
                            onPressed: () {
                              setState(() {
                                _serialLines.clear();
                              });
                            },
                            icon: const Icon(Icons.clear, size: 16),
                            label: const Text('Clear'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 200,
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: _serialLines.isEmpty
                            ? const Center(
                                child: Text(
                                  'Waiting for data...',
                                  style: TextStyle(color: Colors.grey),
                                ),
                              )
                            : ListView.builder(
                                reverse: true, // Show newest at top
                                itemCount: _serialLines.length,
                                itemBuilder: (context, index) {
                                  final line = _serialLines[_serialLines.length - 1 - index];
                                  // Color code: TX lines in cyan, RX lines in green, errors in red
                                  Color textColor;
                                  if (line.contains('TX →')) {
                                    textColor = Colors.cyanAccent;
                                  } else if (line.contains('TX ERROR')) {
                                    textColor = Colors.redAccent;
                                  } else {
                                    textColor = Colors.greenAccent;
                                  }
                                  
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8.0,
                                      vertical: 2.0,
                                    ),
                                    child: SelectableText(
                                      line,
                                      style: TextStyle(
                                        color: textColor,
                                        fontFamily: 'monospace',
                                        fontSize: 12,
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
            // Motion Data
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Live Motion Data',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    _buildMotionRow('X', _motionData['x'] ?? 0.0),
                    _buildMotionRow('Y', _motionData['y'] ?? 0.0),
                    _buildMotionRow('Z', _motionData['z'] ?? 0.0),
                    if (_isCalibrated) ...[
                      const SizedBox(height: 16),
                      const Divider(),
                      const SizedBox(height: 8),
                      const Text(
                        'Baseline',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                      _buildMotionRow('X', _baselineAx),
                      _buildMotionRow('Y', _baselineAy),
                      _buildMotionRow('Z', _baselineAz),
                    ],
                  ],
                ),
              ),
            ),
            const Spacer(),
            // LED Control Buttons
            if (_isConnected) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'LED Control',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () => _sendBleCommand('LED=1'),
                              icon: const Icon(Icons.lightbulb),
                              label: const Text('LED ON'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.amber,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () => _sendBleCommand('LED=0'),
                              icon: const Icon(Icons.lightbulb_outline),
                              label: const Text('LED OFF'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.grey,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            // Reset Button
            ElevatedButton.icon(
              onPressed: _isConnected ? _reset : null,
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reset'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMotionRow(String label, double value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '$label:',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          ),
          Text(
            value.toStringAsFixed(3),
            style: const TextStyle(fontSize: 16, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}
