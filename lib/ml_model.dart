import 'dart:math';

/// Simple on-device machine learning model for posture classification
/// Uses logistic regression for binary classification (good/bad posture)
class PostureMLModel {
  // Model parameters (weights and bias)
  double _weightPitch = 0.0;
  double _weightRoll = 0.0;
  double _weightMovement = 0.0;
  double _bias = 0.0;

  // Extended model parameters
  double goodVectorAx = 0.0;
  double goodVectorAy = 0.0;
  double goodVectorAz = 0.0;
  double goodVectorGx = 0.0;
  double goodVectorGy = 0.0;
  double goodVectorGz = 0.0;
  
  double badVectorAx = 0.0;
  double badVectorAy = 0.0;
  double badVectorAz = 0.0;
  double badVectorGx = 0.0;
  double badVectorGy = 0.0;
  double badVectorGz = 0.0;
  
  double badRadius = 0.0;
  double stabilityIndex = 0.0;
  double sensitivityMultiplier = 1.0;
  double motionIgnoreLevel = 0.5;
  double confidenceScore = 0.0;
  
  int trainedSamples = 0;
  int lastTrainedTimestamp = 0;

  // Training configuration
  static const double learningRate = 0.01;
  static const int maxIterations = 1000;
  static const double convergenceThreshold = 0.0001;

  /// Predict posture state from features
  /// Returns probability of good posture (0.0 to 1.0)
  double predict(double pitchDeg, double rollDeg, double movement) {
    // Linear combination
    double z = _weightPitch * pitchDeg +
               _weightRoll * rollDeg +
               _weightMovement * movement +
               _bias;
    
    // Sigmoid activation
    return 1.0 / (1.0 + exp(-z));
  }

  /// Get binary prediction (true = good, false = bad)
  bool predictBinary(double pitchDeg, double rollDeg, double movement) {
    return predict(pitchDeg, rollDeg, movement) >= 0.5;
  }

  /// Train the model on collected data
  void train(List<TrainingSample> samples) {
    if (samples.isEmpty) return;

    // Initialize weights randomly if not already trained
    if (_weightPitch == 0.0 && _weightRoll == 0.0 && _weightMovement == 0.0) {
      _weightPitch = (Random().nextDouble() - 0.5) * 0.1;
      _weightRoll = (Random().nextDouble() - 0.5) * 0.1;
      _weightMovement = (Random().nextDouble() - 0.5) * 0.1;
      _bias = (Random().nextDouble() - 0.5) * 0.1;
    }

    // Calculate extended parameters from training data
    _calculateExtendedParameters(samples);
    
    // Update training metadata
    trainedSamples = samples.length;
    lastTrainedTimestamp = DateTime.now().millisecondsSinceEpoch;

    // Gradient descent
    for (int iteration = 0; iteration < maxIterations; iteration++) {
      double totalError = 0.0;
      double gradPitch = 0.0;
      double gradRoll = 0.0;
      double gradMovement = 0.0;
      double gradBias = 0.0;

      // Calculate gradients
      for (var sample in samples) {
        double prediction = predict(sample.pitchDeg, sample.rollDeg, sample.movement);
        double error = prediction - (sample.isGood ? 1.0 : 0.0);
        totalError += error * error;

        // Gradients
        gradPitch += error * sample.pitchDeg;
        gradRoll += error * sample.rollDeg;
        gradMovement += error * sample.movement;
        gradBias += error;
      }

      // Average gradients
      int n = samples.length;
      gradPitch /= n;
      gradRoll /= n;
      gradMovement /= n;
      gradBias /= n;

      // Update weights
      _weightPitch -= learningRate * gradPitch;
      _weightRoll -= learningRate * gradRoll;
      _weightMovement -= learningRate * gradMovement;
      _bias -= learningRate * gradBias;

      // Check convergence
      double avgError = totalError / n;
      if (avgError < convergenceThreshold) {
        break;
      }
    }
  }

  /// Calculate extended parameters from training samples
  void _calculateExtendedParameters(List<TrainingSample> samples) {
    // Separate good and bad samples
    List<TrainingSample> goodSamples = samples.where((s) => s.isGood).toList();
    List<TrainingSample> badSamples = samples.where((s) => !s.isGood).toList();
    
    // Calculate good vector (mean of good samples)
    if (goodSamples.isNotEmpty) {
      goodVectorAx = goodSamples.map((s) => s.ax).reduce((a, b) => a + b) / goodSamples.length;
      goodVectorAy = goodSamples.map((s) => s.ay).reduce((a, b) => a + b) / goodSamples.length;
      goodVectorAz = goodSamples.map((s) => s.az).reduce((a, b) => a + b) / goodSamples.length;
      goodVectorGx = goodSamples.map((s) => s.gx).reduce((a, b) => a + b) / goodSamples.length;
      goodVectorGy = goodSamples.map((s) => s.gy).reduce((a, b) => a + b) / goodSamples.length;
      goodVectorGz = goodSamples.map((s) => s.gz).reduce((a, b) => a + b) / goodSamples.length;
    }
    
    // Calculate bad vector (mean of bad samples)
    if (badSamples.isNotEmpty) {
      badVectorAx = badSamples.map((s) => s.ax).reduce((a, b) => a + b) / badSamples.length;
      badVectorAy = badSamples.map((s) => s.ay).reduce((a, b) => a + b) / badSamples.length;
      badVectorAz = badSamples.map((s) => s.az).reduce((a, b) => a + b) / badSamples.length;
      badVectorGx = badSamples.map((s) => s.gx).reduce((a, b) => a + b) / badSamples.length;
      badVectorGy = badSamples.map((s) => s.gy).reduce((a, b) => a + b) / badSamples.length;
      badVectorGz = badSamples.map((s) => s.gz).reduce((a, b) => a + b) / badSamples.length;
      
      // Calculate bad radius (max distance from bad vector)
      double maxDistance = 0.0;
      for (var sample in badSamples) {
        double dist = sqrt(
          pow(sample.ax - badVectorAx, 2) +
          pow(sample.ay - badVectorAy, 2) +
          pow(sample.az - badVectorAz, 2)
        );
        if (dist > maxDistance) maxDistance = dist;
      }
      badRadius = maxDistance;
    }
    
    // Calculate stability index (variance of good samples)
    if (goodSamples.length > 1) {
      double meanAx = goodVectorAx;
      double variance = goodSamples.map((s) => pow(s.ax - meanAx, 2)).reduce((a, b) => a + b) / goodSamples.length;
      stabilityIndex = 1.0 / (1.0 + variance); // Inverse variance, normalized
    } else {
      stabilityIndex = 0.0;
    }
    
    // Calculate sensitivity multiplier (based on separation between good and bad)
    if (goodSamples.isNotEmpty && badSamples.isNotEmpty) {
      double separation = sqrt(
        pow(goodVectorAx - badVectorAx, 2) +
        pow(goodVectorAy - badVectorAy, 2) +
        pow(goodVectorAz - badVectorAz, 2)
      );
      sensitivityMultiplier = separation > 0 ? 1.0 / separation : 1.0;
    }
    
    // Motion ignore level (mean movement of good samples)
    if (goodSamples.isNotEmpty) {
      motionIgnoreLevel = goodSamples.map((s) => s.movement).reduce((a, b) => a + b) / goodSamples.length;
    }
    
    // Calculate confidence score (based on training accuracy)
    int correct = 0;
    for (var sample in samples) {
      bool prediction = predictBinary(sample.pitchDeg, sample.rollDeg, sample.movement);
      if (prediction == sample.isGood) correct++;
    }
    confidenceScore = samples.isNotEmpty ? correct / samples.length : 0.0;
  }

  /// Get model parameters for saving
  Map<String, dynamic> getParameters() {
    return {
      'weightPitch': _weightPitch,
      'weightRoll': _weightRoll,
      'weightMovement': _weightMovement,
      'bias': _bias,
      'goodVectorAx': goodVectorAx,
      'goodVectorAy': goodVectorAy,
      'goodVectorAz': goodVectorAz,
      'goodVectorGx': goodVectorGx,
      'goodVectorGy': goodVectorGy,
      'goodVectorGz': goodVectorGz,
      'badVectorAx': badVectorAx,
      'badVectorAy': badVectorAy,
      'badVectorAz': badVectorAz,
      'badVectorGx': badVectorGx,
      'badVectorGy': badVectorGy,
      'badVectorGz': badVectorGz,
      'badRadius': badRadius,
      'stabilityIndex': stabilityIndex,
      'sensitivityMultiplier': sensitivityMultiplier,
      'motionIgnoreLevel': motionIgnoreLevel,
      'confidenceScore': confidenceScore,
      'trainedSamples': trainedSamples,
      'lastTrainedTimestamp': lastTrainedTimestamp,
    };
  }

  /// Load model parameters
  void loadParameters(Map<String, dynamic> params) {
    _weightPitch = (params['weightPitch'] as num?)?.toDouble() ?? 0.0;
    _weightRoll = (params['weightRoll'] as num?)?.toDouble() ?? 0.0;
    _weightMovement = (params['weightMovement'] as num?)?.toDouble() ?? 0.0;
    _bias = (params['bias'] as num?)?.toDouble() ?? 0.0;
    
    goodVectorAx = (params['goodVectorAx'] as num?)?.toDouble() ?? 0.0;
    goodVectorAy = (params['goodVectorAy'] as num?)?.toDouble() ?? 0.0;
    goodVectorAz = (params['goodVectorAz'] as num?)?.toDouble() ?? 0.0;
    goodVectorGx = (params['goodVectorGx'] as num?)?.toDouble() ?? 0.0;
    goodVectorGy = (params['goodVectorGy'] as num?)?.toDouble() ?? 0.0;
    goodVectorGz = (params['goodVectorGz'] as num?)?.toDouble() ?? 0.0;
    
    badVectorAx = (params['badVectorAx'] as num?)?.toDouble() ?? 0.0;
    badVectorAy = (params['badVectorAy'] as num?)?.toDouble() ?? 0.0;
    badVectorAz = (params['badVectorAz'] as num?)?.toDouble() ?? 0.0;
    badVectorGx = (params['badVectorGx'] as num?)?.toDouble() ?? 0.0;
    badVectorGy = (params['badVectorGy'] as num?)?.toDouble() ?? 0.0;
    badVectorGz = (params['badVectorGz'] as num?)?.toDouble() ?? 0.0;
    
    badRadius = (params['badRadius'] as num?)?.toDouble() ?? 0.0;
    stabilityIndex = (params['stabilityIndex'] as num?)?.toDouble() ?? 0.0;
    sensitivityMultiplier = (params['sensitivityMultiplier'] as num?)?.toDouble() ?? 1.0;
    motionIgnoreLevel = (params['motionIgnoreLevel'] as num?)?.toDouble() ?? 0.5;
    confidenceScore = (params['confidenceScore'] as num?)?.toDouble() ?? 0.0;
    
    trainedSamples = (params['trainedSamples'] as num?)?.toInt() ?? 0;
    lastTrainedTimestamp = (params['lastTrainedTimestamp'] as num?)?.toInt() ?? 0;
  }

  /// Reset model to untrained state
  void reset() {
    _weightPitch = 0.0;
    _weightRoll = 0.0;
    _weightMovement = 0.0;
    _bias = 0.0;
    
    goodVectorAx = 0.0;
    goodVectorAy = 0.0;
    goodVectorAz = 0.0;
    goodVectorGx = 0.0;
    goodVectorGy = 0.0;
    goodVectorGz = 0.0;
    
    badVectorAx = 0.0;
    badVectorAy = 0.0;
    badVectorAz = 0.0;
    badVectorGx = 0.0;
    badVectorGy = 0.0;
    badVectorGz = 0.0;
    
    badRadius = 0.0;
    stabilityIndex = 0.0;
    sensitivityMultiplier = 1.0;
    motionIgnoreLevel = 0.5;
    confidenceScore = 0.0;
    
    trainedSamples = 0;
    lastTrainedTimestamp = 0;
  }

  /// Check if model is trained
  bool get isTrained => _weightPitch != 0.0 || _weightRoll != 0.0 || _weightMovement != 0.0 || _bias != 0.0;
}

/// Training sample for ML model
class TrainingSample {
  final double pitchDeg;
  final double rollDeg;
  final double movement;
  final bool isGood; // true = good posture, false = bad posture
  
  // Raw sensor data
  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;

  TrainingSample({
    required this.pitchDeg,
    required this.rollDeg,
    required this.movement,
    required this.isGood,
    this.ax = 0.0,
    this.ay = 0.0,
    this.az = 0.0,
    this.gx = 0.0,
    this.gy = 0.0,
    this.gz = 0.0,
  });

  Map<String, dynamic> toJson() {
    return {
      'pitchDeg': pitchDeg,
      'rollDeg': rollDeg,
      'movement': movement,
      'isGood': isGood,
      'ax': ax,
      'ay': ay,
      'az': az,
      'gx': gx,
      'gy': gy,
      'gz': gz,
    };
  }

  factory TrainingSample.fromJson(Map<String, dynamic> json) {
    return TrainingSample(
      pitchDeg: (json['pitchDeg'] as num).toDouble(),
      rollDeg: (json['rollDeg'] as num).toDouble(),
      movement: (json['movement'] as num).toDouble(),
      isGood: json['isGood'] as bool,
      ax: (json['ax'] as num?)?.toDouble() ?? 0.0,
      ay: (json['ay'] as num?)?.toDouble() ?? 0.0,
      az: (json['az'] as num?)?.toDouble() ?? 0.0,
      gx: (json['gx'] as num?)?.toDouble() ?? 0.0,
      gy: (json['gy'] as num?)?.toDouble() ?? 0.0,
      gz: (json['gz'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

