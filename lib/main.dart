import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'bluetooth_service.dart';
import 'posture_model.dart';
import 'ml_model.dart';
import 'data_collector.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
  final PostureModel _postureModel = PostureModel();
  final PostureMLModel _mlModel = PostureMLModel();
  final DataCollector _dataCollector = DataCollector();
  
  bool _isConnected = false;
  bool _isPostureGood = false;
  bool _isCalibrated = false; // Device calibration state
  String _calibrationStatus = ''; // Live calibration status message
  int? _calibrationCountdown; // Countdown: 3, 2, 1
  Timer? _calibrationCountdownTimer;
  Map<String, double> _motionData = {
    'x': 0.0,
    'y': 0.0,
    'z': 0.0,
  };
  String _statusMessage = 'Not connected';
  
  // Local AI model state
  PostureState _modelState = PostureState.notCalibrated;
  double _modelBadDeg = 8.0;
  double _modelMovingThreshold = 0.5;
  double _modelBaselinePitch = 0.0;
  double _modelBaselineRoll = 0.0;
  
  // ML model state
  bool _mlModelTrained = false;
  double _mlPrediction = 0.5;
  double _currentPitch = 0.0;
  double _currentRoll = 0.0;
  double _currentMovement = 0.0;
  

  @override
  void initState() {
    super.initState();
    _bluetoothService.onDataReceived = _handleDataReceived;
    _bluetoothService.onConnectionChanged = _handleConnectionChanged;
    _bluetoothService.onCalibrationMessage = _handleCalibrationMessage;
    _loadMLModel();
  }
  
  Future<void> _loadMLModel() async {
    await _dataCollector.loadData();
    await _dataCollector.loadModel(_mlModel);
    if (mounted) {
      setState(() {
        _mlModelTrained = _mlModel.isTrained;
      });
    }
  }

  void _handleDataReceived(Map<String, dynamic> data) {
    // Only process posture data if device is calibrated
    if (!_isCalibrated) {
      return;
    }
    
    if (!mounted) return;
    
    setState(() {
      if (data.containsKey('motion')) {
        _motionData = Map<String, double>.from(data['motion']);
        
        // Feed data to local AI model
        // Convert ax, ay, az to pitch/roll and calculate movement
        double ax = _motionData['x'] ?? 0.0;
        double ay = _motionData['y'] ?? 0.0;
        double az = _motionData['z'] ?? 0.0;
        
        // Calculate pitch and roll from accelerometer
        double pitchDeg = atan2(ax, sqrt(ay * ay + az * az)) * 180.0 / 3.14159;
        double rollDeg = atan2(ay, az) * 180.0 / 3.14159;
        
        // Calculate movement (magnitude of acceleration)
        double movement = sqrt(ax * ax + ay * ay + az * az) - 1.0; // Subtract gravity
        if (movement < 0) movement = 0.0;
        
        int timestampMs = DateTime.now().millisecondsSinceEpoch;
        
        // Store current values for ML model
        _currentPitch = pitchDeg;
        _currentRoll = rollDeg;
        _currentMovement = movement.abs();
        
        // Feed to PostureModel (always running - uses automatic baseline learning)
        _postureModel.ingest(pitchDeg, rollDeg, movement.abs(), timestampMs);
        
        // Update PostureModel state (always running)
        _modelState = _postureModel.state;
        _modelBadDeg = _postureModel.badDeg;
        _modelMovingThreshold = _postureModel.movingThreshold;
        _modelBaselinePitch = _postureModel.baselinePitch;
        _modelBaselineRoll = _postureModel.baselineRoll;
        
        // Get ML model prediction (runs if trained, otherwise shows 0.5)
        bool previousPostureGood = _isPostureGood;
        if (_mlModel.isTrained) {
          // ML Model is running
          _mlPrediction = _mlModel.predict(pitchDeg, rollDeg, movement.abs());
        } else {
          // ML Model not trained yet
          _mlPrediction = 0.5; // Neutral prediction
        }
        
        // Use PostureModel (automatic baseline learning) for posture detection
        if (_postureModel.state == PostureState.ok) {
          _isPostureGood = true;
        } else if (_postureModel.state == PostureState.bad) {
          _isPostureGood = false;
        } else if (_postureModel.state == PostureState.moving) {
          // Keep current state when moving - don't change
        } else if (_postureModel.state == PostureState.notCalibrated) {
          // Fallback to device's posture status if model not calibrated
          if (data.containsKey('posture')) {
            _isPostureGood = data['posture'] == 'GOOD';
          }
        }
      }
    });
  }

  void _handleConnectionChanged(bool connected) {
    if (!mounted) return;
    setState(() {
      _isConnected = connected;
      _statusMessage = connected ? 'Connected to XIAO-Posture' : 'Not connected';
      if (!connected) {
        _isCalibrated = false;
        _calibrationStatus = '';
        _calibrationCountdown = null;
        _calibrationCountdownTimer?.cancel();
        _calibrationCountdownTimer = null;
      }
    });
  }

  void _handleCalibrationMessage(String message) {
    if (!mounted) return;
    
    if (message == 'CAL:GOOD:START' || message == 'CAL:BAD:START') {
      // Start countdown: 3, 2, 1
      _calibrationCountdownTimer?.cancel();
      setState(() {
        _calibrationCountdown = 3;
        _calibrationStatus = message == 'CAL:GOOD:START' 
            ? 'Sit in GOOD posture' 
            : 'Now slouch';
      });
      
      // Countdown timer
      _calibrationCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() {
          if (_calibrationCountdown != null && _calibrationCountdown! > 1) {
            _calibrationCountdown = _calibrationCountdown! - 1;
          } else {
            _calibrationCountdown = null;
            timer.cancel();
          }
        });
      });
    } else if (message == 'CAL:GOOD:DONE' || message == 'CAL:BAD:DONE') {
      // Stop countdown
      _calibrationCountdownTimer?.cancel();
      setState(() {
        _calibrationCountdown = null;
        _calibrationStatus = message == 'CAL:GOOD:DONE' 
            ? 'Saved GOOD posture.' 
            : 'Saved BAD posture.';
      });
    } else if (message == 'CAL:DONE') {
      // Stop countdown
      _calibrationCountdownTimer?.cancel();
      setState(() {
        _calibrationCountdown = null;
        _calibrationStatus = 'Calibration complete.';
        _isCalibrated = true;
      });
    }
  }

  Future<void> _connectToDevice() async {
    try {
      await _bluetoothService.connectToDevice('XIAO-Posture');
      
      // Send start command to device after successful connection
      try {
        await _bluetoothService.start();
      } catch (e) {
        // Log but don't fail connection if start command fails
        print('Warning: Failed to send start command: $e');
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


  Future<void> _reset() async {
    try {
      await _bluetoothService.reset();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reset command sent')),
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

  void _addFeedback(bool isGood) {
    // Get sensor data from motion data
    double ax = _motionData['x'] ?? 0.0;
    double ay = _motionData['y'] ?? 0.0;
    double az = _motionData['z'] ?? 0.0;
    // Gyroscope data not available in current data structure, set to 0
    double gx = 0.0;
    double gy = 0.0;
    double gz = 0.0;
    
    _dataCollector.addSample(
      _currentPitch, 
      _currentRoll, 
      _currentMovement, 
      isGood,
      ax: ax,
      ay: ay,
      az: az,
      gx: gx,
      gy: gy,
      gz: gz,
    );
    setState(() {});
    _dataCollector.saveData();
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Feedback recorded! (${_dataCollector.sampleCount} samples)'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<void> _trainModel() async {
    if (_dataCollector.sampleCount < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Need at least 10 samples to train')),
      );
      return;
    }

    setState(() {
      _mlModel.train(_dataCollector.samples);
      _mlModelTrained = _mlModel.isTrained;
    });

    await _dataCollector.saveModel(_mlModel);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Model trained on ${_dataCollector.sampleCount} samples!'),
        backgroundColor: Colors.green,
      ),
    );
  }

  Future<void> _exportModelParameters() async {
    if (!_mlModelTrained) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Model not trained yet. Train the model first.')),
      );
      return;
    }

    try {
      final filePath = await _dataCollector.exportModelParameters(_mlModel);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Model parameters exported to:\n$filePath'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }



  Future<void> _sendCalGood() async {
    try {
      await _bluetoothService.sendCalGood();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send calibration: $e')),
        );
      }
    }
  }

  Future<void> _sendCalBad() async {
    try {
      await _bluetoothService.sendCalBad();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send calibration: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _calibrationCountdownTimer?.cancel();
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
      body: Stack(
        children: [
          Padding(
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
            // Calibration Section
            if (_isConnected) ...[
              const SizedBox(height: 24),
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
                            _isCalibrated ? 'Device Calibrated' : 'Device Not Calibrated',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: _isCalibrated ? Colors.green : Colors.orange,
                            ),
                          ),
                        ],
                      ),
                      if (_calibrationStatus.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        if (_calibrationCountdown != null) ...[
                          // Show large countdown number
                          Text(
                            '$_calibrationCountdown',
                            style: TextStyle(
                              fontSize: 72,
                              fontWeight: FontWeight.bold,
                              color: _calibrationStatus.contains('GOOD') 
                                  ? Colors.green 
                                  : Colors.red,
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        Text(
                          _calibrationStatus,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: _calibrationCountdown != null 
                                ? FontWeight.bold 
                                : FontWeight.normal,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      if (!_isCalibrated) ...[
                        const SizedBox(height: 16),
                        const Text(
                          'Calibrate the device before monitoring posture:',
                          style: TextStyle(fontSize: 14),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: _sendCalGood,
                                icon: const Icon(Icons.arrow_upward),
                                label: const Text('I\'m sitting straight'),
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
                                onPressed: _sendCalBad,
                                icon: const Icon(Icons.arrow_downward),
                                label: const Text('I\'m slouching'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            // Posture Status
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'Posture Status',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: _modelState == PostureState.notCalibrated 
                                ? Colors.orange.shade100 
                                : Colors.green.shade100,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _modelState == PostureState.notCalibrated 
                                ? 'Not Calibrated' 
                                : 'PostureModel',
                            style: TextStyle(
                              fontSize: 10, 
                              color: _modelState == PostureState.notCalibrated 
                                  ? Colors.orange 
                                  : Colors.green,
                            ),
                          ),
                        ),
                      ],
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
                          'CALIBRATE DEVICE',
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
            // Local AI Model Status
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Local AI Model Status',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    _buildInfoRow('State', _getStateText(_modelState)),
                    _buildInfoRow('Baseline Pitch', '${_modelBaselinePitch.toStringAsFixed(2)}°'),
                    _buildInfoRow('Baseline Roll', '${_modelBaselineRoll.toStringAsFixed(2)}°'),
                    _buildInfoRow('Bad Threshold', '${_modelBadDeg.toStringAsFixed(2)}°'),
                    _buildInfoRow('Moving Threshold', _modelMovingThreshold.toStringAsFixed(3)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
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
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            // ML Model Section
            Card(
              color: _mlModelTrained ? Colors.green.shade50 : Colors.grey.shade100,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'Personalized ML Model',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        if (_mlModelTrained)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.green,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              'Trained',
                              style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          )
                        else
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.orange,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              'Not Trained',
                              style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Icon(
                          _mlModelTrained ? Icons.check_circle : Icons.pause_circle,
                          color: _mlModelTrained ? Colors.green : Colors.orange,
                          size: 16,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _mlModelTrained ? 'MLModel: Running' : 'MLModel: Not Trained',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: _mlModelTrained ? Colors.green : Colors.orange,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_mlModelTrained) ...[
                      _buildInfoRow('Prediction', '${(_mlPrediction * 100).toStringAsFixed(1)}% good'),
                      _buildInfoRow('Samples', '${_dataCollector.sampleCount}'),
                    ] else ...[
                      _buildInfoRow('Prediction', 'N/A (not trained)'),
                      _buildInfoRow('Samples', '${_dataCollector.sampleCount}'),
                      const SizedBox(height: 8),
                      const Text(
                        'Collect data and provide feedback to train your personal model',
                        style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                      ),
                    ],
                    const SizedBox(height: 12),
                    // Data collection toggle
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isConnected ? () {
                              setState(() {
                                if (_dataCollector.isCollecting) {
                                  _dataCollector.stopCollecting();
                                } else {
                                  _dataCollector.startCollecting();
                                }
                              });
                            } : null,
                            icon: Icon(_dataCollector.isCollecting ? Icons.stop : Icons.play_arrow),
                            label: Text(_dataCollector.isCollecting ? 'Stop Collecting' : 'Start Collecting'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _dataCollector.isCollecting ? Colors.red : Colors.blue,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _dataCollector.sampleCount >= 10 ? _trainModel : null,
                            icon: const Icon(Icons.school),
                            label: const Text('Train Model'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_mlModelTrained) ...[
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        onPressed: _exportModelParameters,
                        icon: const Icon(Icons.download),
                        label: const Text('Export Parameters to TXT'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    // Feedback buttons
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isConnected && _dataCollector.isCollecting
                                ? () => _addFeedback(true)
                                : null,
                            icon: const Icon(Icons.thumb_up),
                            label: const Text('Good Posture'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isConnected && _dataCollector.isCollecting
                                ? () => _addFeedback(false)
                                : null,
                            icon: const Icon(Icons.thumb_down),
                            label: const Text('Bad Posture'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            // Control Buttons
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
        ],
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
            value.toStringAsFixed(2),
            style: const TextStyle(fontSize: 16, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '$label:',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }

  String _getStateText(PostureState state) {
    switch (state) {
      case PostureState.notCalibrated:
        return 'Not Calibrated';
      case PostureState.ok:
        return 'OK';
      case PostureState.bad:
        return 'BAD';
      case PostureState.moving:
        return 'Moving';
    }
  }
}

