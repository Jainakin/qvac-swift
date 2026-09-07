import Foundation

/// Exact base64 output length without performing an allocation.
///
/// Keeping this arithmetic in one checked helper lets binary convenience APIs
/// reject requests that cannot fit the configured wire ceiling before creating
/// a larger base64 `String` and JSON payload.
func qvacBase64EncodedByteCount(_ byteCount: Int) -> Int? {
    guard byteCount >= 0 else { return nil }
    let fullGroups = byteCount / 3
    let (encodedFullGroups, multiplicationOverflow) = fullGroups.multipliedReportingOverflow(
        by: 4
    )
    guard !multiplicationOverflow else { return nil }
    let tail = byteCount.isMultiple(of: 3) ? 0 : 4
    let (result, additionOverflow) = encodedFullGroups.addingReportingOverflow(tail)
    return additionOverflow ? nil : result
}
