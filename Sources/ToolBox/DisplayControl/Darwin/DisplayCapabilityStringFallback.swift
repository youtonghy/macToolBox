import Foundation

/// Verified capability strings used only when live DDC capability reading
/// fails. This mirrors DDPM's own capability cache/allowlist: DDPM persists
/// verified capability strings per model and treats known models as supported
/// even when a later live `0xF3` request is refused.
enum DisplayCapabilityStringFallback {
    static func capabilityString(forModelName modelName: String?) -> String? {
        guard let name = modelName?.uppercased() else { return nil }
        if name.contains("U2723QE") {
            return Self.u2723qe
        }
        return nil
    }

    /// Dell U2723QE, firmware M2T105. Decrypted from DDPM's own
    /// `DDPM_CapabilityString.json` cache (created 2026-05-15) using the
    /// app's AES keychain key, so these are the monitor's real advertised
    /// values, not guesses.
    private static let u2723qe = """
    (prot(monitor)type(lcd)model(U2723QE)cmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(01 04 05 06 08 09 0B 0C) 16 18 1A 52 60( 1B 0F 11) AA(01 02 04) AC AE B2 B6 C6 C8 C9 CC(02 03 04 06 09 0A 0D 0E) D6(01 04 05) DC(00 03 05) DF E0 E1 E2(00 02 04 0C 0D 0F 10 11 13 0B 1B 1A 14 23 24 27 3A) E5 E7(02 03) E8 E9(00 01 02 21 22 24) EA EF F0(00 05 06 09 0A 31 32 34 36) F1 F2 FE FD)mccs_ver(2.1)mswhql(1))
    """
}
