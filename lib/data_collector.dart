import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'ml_model.dart';

/// Collects and manages training data for the ML model
class DataCollector {
  static const String dataFileName = 'posture_training_data.json';
  static const String modelFileName = 'posture_model_params.json';
  
  final List<TrainingSample> _samples = [];
  bool _isCollecting = false;

  List<TrainingSample> get samples => List.unmodifiable(_samples);
  bool get isCollecting => _isCollecting;
  int get sampleCount => _samples.length;

  /// Start collecting data
  void startCollecting() {
    _isCollecting = true;
  }

  /// Stop collecting data
  void stopCollecting() {
    _isCollecting = false;
  }

  /// Add a training sample
  void addSample(double pitchDeg, double rollDeg, double movement, bool isGood, {
    double ax = 0.0,
    double ay = 0.0,
    double az = 0.0,
    double gx = 0.0,
    double gy = 0.0,
    double gz = 0.0,
  }) {
    if (!_isCollecting) return;
    
    _samples.add(TrainingSample(
      pitchDeg: pitchDeg,
      rollDeg: rollDeg,
      movement: movement,
      isGood: isGood,
      ax: ax,
      ay: ay,
      az: az,
      gx: gx,
      gy: gy,
      gz: gz,
    ));
  }

  /// Clear all collected samples
  void clearSamples() {
    _samples.clear();
  }

  /// Save training data to file
  Future<void> saveData() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/$dataFileName');
      
      final jsonData = _samples.map((s) => s.toJson()).toList();
      await file.writeAsString(jsonEncode(jsonData));
    } catch (e) {
      print('Error saving data: $e');
    }
  }

  /// Load training data from file
  Future<void> loadData() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/$dataFileName');
      
      if (!await file.exists()) return;
      
      final jsonString = await file.readAsString();
      final jsonData = jsonDecode(jsonString) as List;
      
      _samples.clear();
      _samples.addAll(
        jsonData.map((json) => TrainingSample.fromJson(json as Map<String, dynamic>))
      );
    } catch (e) {
      print('Error loading data: $e');
    }
  }

  /// Save model parameters to file
  Future<void> saveModel(PostureMLModel model) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/$modelFileName');
      
      final params = model.getParameters();
      await file.writeAsString(jsonEncode(params));
    } catch (e) {
      print('Error saving model: $e');
    }
  }

  /// Load model parameters from file
  Future<void> loadModel(PostureMLModel model) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/$modelFileName');
      
      if (!await file.exists()) return;
      
      final jsonString = await file.readAsString();
      final params = jsonDecode(jsonString) as Map<String, dynamic>;
      
      model.loadParameters(params);
    } catch (e) {
      print('Error loading model: $e');
    }
  }

  /// Export model parameters to a text file
  Future<String> exportModelParameters(PostureMLModel model) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/ml_model_parameters.txt');
      
      final params = model.getParameters();
      final timestamp = DateTime.fromMillisecondsSinceEpoch(
        params['lastTrainedTimestamp'] as int? ?? 0
      ).toIso8601String();
      
      final content = StringBuffer();
      content.writeln('ML Model Parameters Export');
      content.writeln('==========================');
      content.writeln('');
      content.writeln('Good Vector:');
      content.writeln('  good_vector_ax = ${params['goodVectorAx']}');
      content.writeln('  good_vector_ay = ${params['goodVectorAy']}');
      content.writeln('  good_vector_az = ${params['goodVectorAz']}');
      content.writeln('  good_vector_gx = ${params['goodVectorGx']}');
      content.writeln('  good_vector_gy = ${params['goodVectorGy']}');
      content.writeln('  good_vector_gz = ${params['goodVectorGz']}');
      content.writeln('');
      content.writeln('Bad Vector:');
      content.writeln('  bad_vector_ax = ${params['badVectorAx']}');
      content.writeln('  bad_vector_ay = ${params['badVectorAy']}');
      content.writeln('  bad_vector_az = ${params['badVectorAz']}');
      content.writeln('  bad_vector_gx = ${params['badVectorGx']}');
      content.writeln('  bad_vector_gy = ${params['badVectorGy']}');
      content.writeln('  bad_vector_gz = ${params['badVectorGz']}');
      content.writeln('');
      content.writeln('Thresholds:');
      content.writeln('  bad_radius = ${params['badRadius']}');
      content.writeln('  stability_index = ${params['stabilityIndex']}');
      content.writeln('  sensitivity_multiplier = ${params['sensitivityMultiplier']}');
      content.writeln('  motion_ignore_level = ${params['motionIgnoreLevel']}');
      content.writeln('');
      content.writeln('Model Metrics:');
      content.writeln('  confidence_score = ${params['confidenceScore']}');
      content.writeln('  trained_samples = ${params['trainedSamples']}');
      content.writeln('  last_trained_timestamp = $timestamp');
      
      await file.writeAsString(content.toString());
      return file.path;
    } catch (e) {
      print('Error exporting model parameters: $e');
      rethrow;
    }
  }
}

