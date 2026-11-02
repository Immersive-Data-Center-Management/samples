package org.godotengine.plugin.android.arcore;

import android.content.Context;
import android.graphics.Rect;

import com.google.mlkit.vision.barcode.BarcodeScanner;
import com.google.mlkit.vision.barcode.BarcodeScannerOptions;
import com.google.mlkit.vision.barcode.BarcodeScanning;
import com.google.mlkit.vision.barcode.common.Barcode;
import com.google.mlkit.vision.common.InputImage;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;

/**
 * JNI bridge for ML Kit Barcode Scanning.
 * Called from C++ QRScanner via JNI.
 */
public class QRScannerBridge {
    private final BarcodeScanner scanner;
    private static final byte[] EMPTY_RESULT = new byte[] { 0, 0, 0, 0 };

    private static final class PackedDetection {
        final byte[] rawUtf8;
        final byte[] formatUtf8;
        final int left;
        final int top;
        final int right;
        final int bottom;

        PackedDetection(byte[] pRawUtf8, byte[] pFormatUtf8, int pLeft, int pTop, int pRight, int pBottom) {
            rawUtf8 = pRawUtf8;
            formatUtf8 = pFormatUtf8;
            left = pLeft;
            top = pTop;
            right = pRight;
            bottom = pBottom;
        }
    }

    public QRScannerBridge(Context context) {
        BarcodeScannerOptions options = new BarcodeScannerOptions.Builder()
                .setBarcodeFormats(
                        Barcode.FORMAT_QR_CODE,
                        Barcode.FORMAT_DATA_MATRIX,
                        Barcode.FORMAT_AZTEC)
                .build();
        scanner = BarcodeScanning.getClient(options);
    }

    /**
     * Synchronous scan of a grayscale (Y-plane) image.
         * Returns a packed byte array:
         * [u32 count]
         * repeated count times:
        *   [i32 left, i32 top, i32 right, i32 bottom,
        *    u32 data_len, u8[data_len] raw_utf8,
        *    u32 format_len, u8[format_len] format_utf8]
     *
     * @param imageData  Grayscale (Y-plane) byte array
     * @param width      Image width
     * @param height     Image height
     * @param rotation   Image rotation (0, 90, 180, 270)
         * @return Packed detection payload, or null if scanning failed
     */
        public byte[] scanImage(byte[] imageData, int width, int height, int rotation) {
        try {
            InputImage inputImage = InputImage.fromByteArray(
                    imageData, width, height, rotation,
                    InputImage.IMAGE_FORMAT_NV21);

            final List<PackedDetection> results = new ArrayList<>();
            final CountDownLatch latch = new CountDownLatch(1);
            final Exception[] error = new Exception[1];

            scanner.process(inputImage)
                    .addOnSuccessListener(barcodes -> {
                        for (Barcode barcode : barcodes) {
                            String rawValue = barcode.getRawValue();
                            if (rawValue == null) continue;
                            byte[] rawUtf8 = rawValue.getBytes(StandardCharsets.UTF_8);
                            byte[] formatUtf8 = formatToString(barcode.getFormat()).getBytes(StandardCharsets.UTF_8);
                            Rect bounds = barcode.getBoundingBox();

                            int left = bounds != null ? bounds.left : 0;
                            int top = bounds != null ? bounds.top : 0;
                            int right = bounds != null ? bounds.right : width;
                            int bottom = bounds != null ? bounds.bottom : height;

                            results.add(new PackedDetection(
                                    rawUtf8,
                                    formatUtf8,
                                    left,
                                    top,
                                    right,
                                    bottom));

                        }
                        latch.countDown();
                    })
                    .addOnFailureListener(e -> {
                        error[0] = e;
                        android.util.Log.e("QRScannerBridge", "ML Kit scanning failed", e);
                        latch.countDown();
                    });

            try {
                // Wait up to 500ms for ML Kit to process
                boolean completed = latch.await(500, TimeUnit.MILLISECONDS);
                if (!completed) {
                    android.util.Log.w("QRScannerBridge", "ML Kit scanning timed out after 500ms");
                }
            } catch (InterruptedException e) {
                android.util.Log.e("QRScannerBridge", "Interrupted while waiting for ML Kit", e);
            }

            if (error[0] != null) {
                return null;  // Error occurred
            }

            if (results.isEmpty()) {
                return EMPTY_RESULT;
            }

            int totalSize = 4;
            for (PackedDetection d : results) {
                totalSize += 4 + 4 + 4 + 4 + 4 + d.rawUtf8.length + 4 + d.formatUtf8.length;
            }

            ByteBuffer out = ByteBuffer.allocate(totalSize).order(ByteOrder.LITTLE_ENDIAN);
            out.putInt(results.size());
            for (PackedDetection d : results) {
                out.putInt(d.left);
                out.putInt(d.top);
                out.putInt(d.right);
                out.putInt(d.bottom);
                out.putInt(d.rawUtf8.length);
                out.put(d.rawUtf8);
                out.putInt(d.formatUtf8.length);
                out.put(d.formatUtf8);
            }
            return out.array();
        } catch (Exception e) {
            android.util.Log.e("QRScannerBridge", "Exception in scanImage", e);
            return null;
        }
    }

    private static String formatToString(int format) {
        switch (format) {
            case Barcode.FORMAT_QR_CODE: return "QR_CODE";
            case Barcode.FORMAT_DATA_MATRIX: return "DATA_MATRIX";
            case Barcode.FORMAT_AZTEC: return "AZTEC";
            case Barcode.FORMAT_EAN_13: return "EAN_13";
            case Barcode.FORMAT_EAN_8: return "EAN_8";
            case Barcode.FORMAT_UPC_A: return "UPC_A";
            case Barcode.FORMAT_UPC_E: return "UPC_E";
            case Barcode.FORMAT_CODE_128: return "CODE_128";
            case Barcode.FORMAT_CODE_39: return "CODE_39";
            case Barcode.FORMAT_CODE_93: return "CODE_93";
            case Barcode.FORMAT_ITF: return "ITF";
            case Barcode.FORMAT_PDF417: return "PDF417";
            case Barcode.FORMAT_CODABAR: return "CODABAR";
            default: return "UNKNOWN";
        }
    }
}
