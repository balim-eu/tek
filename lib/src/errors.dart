class TekException implements Exception {
  TekException(this.code, this.message, {this.exitCode = 1, this.details});

  final String code;
  final String message;
  final int exitCode;
  final Map<String, Object?>? details;

  Map<String, Object?> toJson() => {
        'code': code,
        'message': message,
        if (details != null) 'details': details,
      };

  @override
  String toString() => '$code: $message';
}

abstract final class ErrorCodes {
  static const usage = 'USAGE_ERROR';
  static const invalidReference = 'INVALID_ARCHITECTURE_REFERENCE';
  static const invalidConstraint = 'INVALID_VERSION_CONSTRAINT';
  static const architectureNotFound = 'ARCHITECTURE_NOT_FOUND';
  static const versionNotFound = 'VERSION_NOT_FOUND';
  static const noRegistries = 'NO_REGISTRIES';
  static const registryNotFound = 'REGISTRY_NOT_FOUND';
  static const registryExists = 'REGISTRY_EXISTS';
  static const registryUnavailable = 'REGISTRY_UNAVAILABLE';
  static const invalidRegistry = 'INVALID_REGISTRY';
  static const unsupportedRegistryType = 'UNSUPPORTED_REGISTRY_TYPE';
  static const unsupportedSchemaVersion = 'UNSUPPORTED_SCHEMA_VERSION';
  static const insecureUrl = 'INSECURE_URL';
  static const authenticationRequired = 'AUTHENTICATION_REQUIRED';
  static const authenticationFailed = 'AUTHENTICATION_FAILED';
  static const accessDenied = 'ACCESS_DENIED';
  static const downloadFailed = 'DOWNLOAD_FAILED';
  static const checksumMismatch = 'CHECKSUM_MISMATCH';
  static const installConflict = 'INSTALL_CONFLICT';
  static const invalidPackage = 'INVALID_PACKAGE';
  static const invalidManifest = 'INVALID_MANIFEST';
  static const notInstalled = 'NOT_INSTALLED';
  static const integrityCheckFailed = 'INTEGRITY_CHECK_FAILED';
  static const commandNotFound = 'COMMAND_NOT_FOUND';
  static const commandFailed = 'COMMAND_FAILED';
  static const requirementsNotMet = 'REQUIREMENTS_NOT_MET';
  static const unsupportedPlatform = 'UNSUPPORTED_PLATFORM';
  static const updateFailed = 'UPDATE_FAILED';
  static const config = 'INVALID_CONFIG';
  static const io = 'IO_ERROR';
  static const internal = 'INTERNAL_ERROR';
}
