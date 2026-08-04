/// Compact labels for Navigation SDK time/distance values.
String formatNavDuration(int seconds) {
  if (seconds <= 0) return '--';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (hours > 0) {
    return minutes > 0 ? '$hours hr $minutes min' : '$hours hr';
  }
  if (minutes > 0) return '$minutes min';
  return '${seconds}s';
}

String formatNavDistance(int meters) {
  if (meters <= 0) return '--';
  if (meters >= 1000) {
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }
  return '$meters m';
}

String formatNavArrivalTime(int remainingSeconds) {
  final arrival = DateTime.now().add(Duration(seconds: remainingSeconds));
  final hour = arrival.hour % 12 == 0 ? 12 : arrival.hour % 12;
  final minute = arrival.minute.toString().padLeft(2, '0');
  final suffix = arrival.hour >= 12 ? 'PM' : 'AM';
  return '$hour:$minute $suffix';
}
