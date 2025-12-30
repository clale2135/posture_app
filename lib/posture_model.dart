import 'dart:math';

/// PostureModel - Analyzes pitch, roll, and movement to determine posture state
/// Uses rolling statistics and adaptive thresholds for real-time posture detection

enum PostureState {
  notCalibrated, // Baseline not yet learned
  ok,            // Good posture
  bad,           // Bad posture (sustained)
  moving,        // Too much movement to assess posture
}

class PostureModel {
  // Configuration
  static const int badMs = 500; // Duration to sustain bad posture before confirming (very sensitive - 0.5 second)
  static const double lowMovementThreshold = 0.1; // Threshold for considering movement "low"
  static const int minSamplesForCalibration = 10; // Minimum samples needed for baseline
  static const int rollingWindowSize = 50; // Number of samples for rolling statistics

  // Baseline values (learned automatically)
  double baselinePitch = 0.0;
  double baselineRoll = 0.0;
  bool _isCalibrated = false;

  // Rolling statistics for pitch deviation
  final List<double> _pitchDeviations = [];
  
  // Rolling statistics for movement
  final List<double> _movements = [];

  // Low-movement samples for baseline learning
  final List<double> _lowMovementPitches = [];
  final List<double> _lowMovementRolls = [];

  // Adaptive thresholds
  double badDeg = 2.0; // Initial threshold (extremely sensitive)
  double movingThreshold = 0.5; // Initial threshold

  // Current state
  PostureState state = PostureState.notCalibrated;

  // Bad posture tracking
  int? _badPostureStartTime;
  bool _isBadPostureSustained = false;

  /// Ingest a new sample and update posture analysis
  void ingest(double pitchDeg, double rollDeg, double movement, int timestampMs) {
    // Update rolling statistics for movement
    _movements.add(movement);
    if (_movements.length > rollingWindowSize) {
      _movements.removeAt(0);
    }

    // Collect low-movement samples for baseline learning
    if (!_isCalibrated) {
      if (movement < lowMovementThreshold) {
        _lowMovementPitches.add(pitchDeg);
        _lowMovementRolls.add(rollDeg);
        
        // Keep only recent samples
        if (_lowMovementPitches.length > rollingWindowSize) {
          _lowMovementPitches.removeAt(0);
          _lowMovementRolls.removeAt(0);
        }
        
        // Learn baseline when we have enough low-movement samples
        if (_lowMovementPitches.length >= minSamplesForCalibration) {
          _learnBaseline();
        }
      }
    }

    // If not calibrated yet, state is notCalibrated
    if (!_isCalibrated) {
      state = PostureState.notCalibrated;
      return;
    }

    // Calculate pitch deviation from baseline
    double pitchDeviation = (pitchDeg - baselinePitch).abs();

    // Update rolling statistics for pitch deviation
    _pitchDeviations.add(pitchDeviation);
    if (_pitchDeviations.length > rollingWindowSize) {
      _pitchDeviations.removeAt(0);
    }

    // Recalculate adaptive thresholds
    _updateThresholds();

    // Determine current state
    _updateState(movement, pitchDeviation, timestampMs);
  }

  /// Learn baseline pitch and roll from recent low-movement samples
  void _learnBaseline() {
    if (_lowMovementPitches.length < minSamplesForCalibration) return;

    // Calculate mean of low-movement pitch and roll samples
    baselinePitch = _calculateMean(_lowMovementPitches);
    baselineRoll = _calculateMean(_lowMovementRolls);
    
    _isCalibrated = true;
    state = PostureState.ok;
  }

  /// Manually calibrate baseline with current pitch and roll values
  void calibrateNow(double pitchDeg, double rollDeg) {
    baselinePitch = pitchDeg;
    baselineRoll = rollDeg;
    _isCalibrated = true;
    _badPostureStartTime = null;
    _isBadPostureSustained = false;
    state = PostureState.ok;
  }

  /// Update adaptive thresholds based on rolling statistics
  void _updateThresholds() {
    if (_pitchDeviations.isEmpty || _movements.isEmpty) return;

    // Calculate mean and standard deviation for pitch deviation
    double pitchMean = _calculateMean(_pitchDeviations);
    double pitchStd = _calculateStdDev(_pitchDeviations, pitchMean);

    // Calculate mean and standard deviation for movement
    double movementMean = _calculateMean(_movements);
    double movementStd = _calculateStdDev(_movements, movementMean);

    // Adaptive threshold: badDeg = clamp(1.2 * pitchStd, 2, 12)
    // Extremely sensitive: lower minimum (2°), lower multiplier (1.2x), lower max (12°) for very easy detection
    badDeg = _clamp(1.2 * pitchStd, 2.0, 12.0);

    // Adaptive threshold: movingThreshold = movementMean + 2 * movementStd
    movingThreshold = movementMean + 2.0 * movementStd;
  }

  /// Update current posture state based on movement and pitch deviation
  void _updateState(double movement, double pitchDeviation, int timestampMs) {
    // Check if movement is too high
    if (movement > movingThreshold) {
      state = PostureState.moving;
      _badPostureStartTime = null;
      _isBadPostureSustained = false;
      return;
    }

    // Check if pitch deviation exceeds threshold
    if (pitchDeviation > badDeg) {
      // Bad posture detected
      if (_badPostureStartTime == null) {
        // Start tracking bad posture duration
        _badPostureStartTime = timestampMs;
        _isBadPostureSustained = false;
        state = PostureState.ok; // Not yet confirmed as bad
      } else {
        // Check if bad posture has been sustained for badMs
        int duration = timestampMs - _badPostureStartTime!;
        if (duration >= badMs && !_isBadPostureSustained) {
          _isBadPostureSustained = true;
          state = PostureState.bad;
        } else if (_isBadPostureSustained) {
          state = PostureState.bad;
        } else {
          state = PostureState.ok; // Still waiting for confirmation
        }
      }
    } else {
      // Good posture
      _badPostureStartTime = null;
      _isBadPostureSustained = false;
      state = PostureState.ok;
    }
  }

  /// Calculate mean of a list of values
  double _calculateMean(List<double> values) {
    if (values.isEmpty) return 0.0;
    double sum = values.fold(0.0, (a, b) => a + b);
    return sum / values.length;
  }

  /// Calculate standard deviation of a list of values
  double _calculateStdDev(List<double> values, double mean) {
    if (values.isEmpty || values.length == 1) return 0.0;
    double variance = values.fold(0.0, (sum, value) {
      double diff = value - mean;
      return sum + (diff * diff);
    }) / values.length;
    return variance > 0 ? sqrt(variance) : 0.0;
  }

  /// Clamp a value between min and max
  double _clamp(double value, double min, double max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  /// Reset the model (clear all statistics and calibration)
  void reset() {
    baselinePitch = 0.0;
    baselineRoll = 0.0;
    _isCalibrated = false;
    _pitchDeviations.clear();
    _movements.clear();
    _lowMovementPitches.clear();
    _lowMovementRolls.clear();
    badDeg = 2.0;
    movingThreshold = 0.5;
    state = PostureState.notCalibrated;
    _badPostureStartTime = null;
    _isBadPostureSustained = false;
  }
}

