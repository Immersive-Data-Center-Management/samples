#ifndef ARCORE_FEATURES_H
#define ARCORE_FEATURES_H

// Optional features that bring additional dependencies.
// Disable to reduce APK size and remove external library requirements.

// QR Scanner: Requires Google ML Kit Barcode Scanning (Java dependency).
// When disabled, QRScanner class becomes an empty stub and ML Kit is not linked.
#define ARCORE_FEATURE_QR_SCANNER 1

#endif // ARCORE_FEATURES_H
