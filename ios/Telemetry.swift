import Foundation

struct Telemetry: Codable, Equatable {
    var seq: UInt32 = 0
    var ms: UInt32 = 0
    var ts_ms: UInt32 = 0
    var source: String = "waiting"

    var rpm: Double = .nan
    var speed: Double = .nan
    var speed_kph: Double = .nan
    var gear: String = "N"
    var fuel_pct: Double = .nan
    var ambient_c: Double = .nan

    var coolant: Double = .nan
    var coolant_c: Double = .nan
    var engine_temp_c: Double = .nan
    var iat: Double = .nan
    var iat_c: Double = .nan
    var map: Double = .nan
    var map_kpa: Double = .nan
    var tps: Double = .nan
    var tps_pct: Double = .nan
    var vbatt: Double = .nan
    var battery_v: Double = .nan

    var lambda: Double = .nan
    var afr: Double = .nan
    var ignition_deg: Double = .nan
    var injector_ms: Double = .nan
    var engine_load_pct: Double = .nan
    var fuel_rate_lph: Double = .nan
    var range_km: Double = .nan
    var oil_temp_c: Double = .nan

    var fan_on: Bool = false
    var mil_on: Bool = false
    var dtc_count: Int = 0
    var link_quality_pct: Double = .nan
    var can_bitrate: Int = 0

    static let placeholder = Telemetry()

    enum CodingKeys: String, CodingKey {
        case seq, ms, ts_ms, source
        case rpm, speed, speed_kph, gear, fuel_pct, ambient_c
        case coolant, coolant_c, engine_temp_c, iat, iat_c, map, map_kpa, tps, tps_pct, vbatt, battery_v
        case lambda, afr, ignition_deg, injector_ms, engine_load_pct, fuel_rate_lph, range_km, oil_temp_c
        case fan_on, mil_on, dtc_count, link_quality_pct, can_bitrate
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decodeIfPresent(UInt32.self, forKey: .seq) ?? 0
        ms = try c.decodeIfPresent(UInt32.self, forKey: .ms) ?? 0
        ts_ms = try c.decodeIfPresent(UInt32.self, forKey: .ts_ms) ?? ms
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "telemetry"

        rpm = Self.double(c, .rpm)
        speed = Self.double(c, .speed)
        speed_kph = Self.double(c, .speed_kph)
        gear = try c.decodeIfPresent(String.self, forKey: .gear) ?? "N"
        fuel_pct = Self.double(c, .fuel_pct)
        ambient_c = Self.double(c, .ambient_c)

        coolant = Self.double(c, .coolant)
        coolant_c = Self.double(c, .coolant_c)
        engine_temp_c = Self.double(c, .engine_temp_c)
        iat = Self.double(c, .iat)
        iat_c = Self.double(c, .iat_c)
        map = Self.double(c, .map)
        map_kpa = Self.double(c, .map_kpa)
        tps = Self.double(c, .tps)
        tps_pct = Self.double(c, .tps_pct)
        vbatt = Self.double(c, .vbatt)
        battery_v = Self.double(c, .battery_v)

        lambda = Self.double(c, .lambda)
        afr = Self.double(c, .afr)
        ignition_deg = Self.double(c, .ignition_deg)
        injector_ms = Self.double(c, .injector_ms)
        engine_load_pct = Self.double(c, .engine_load_pct)
        fuel_rate_lph = Self.double(c, .fuel_rate_lph)
        range_km = Self.double(c, .range_km)
        oil_temp_c = Self.double(c, .oil_temp_c)

        fan_on = try c.decodeIfPresent(Bool.self, forKey: .fan_on) ?? false
        mil_on = try c.decodeIfPresent(Bool.self, forKey: .mil_on) ?? false
        dtc_count = try c.decodeIfPresent(Int.self, forKey: .dtc_count) ?? 0
        link_quality_pct = Self.double(c, .link_quality_pct)
        can_bitrate = try c.decodeIfPresent(Int.self, forKey: .can_bitrate) ?? 0
    }

    private static func double(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double {
        (try? c.decodeIfPresent(Double.self, forKey: key)) ?? .nan
    }

    var displaySpeed: Double { speed_kph.isFinite ? speed_kph : speed }
    var displayCoolant: Double { coolant_c.isFinite ? coolant_c : coolant }
    var displayIAT: Double { iat_c.isFinite ? iat_c : iat }
    var displayMAP: Double { map_kpa.isFinite ? map_kpa : map }
    var displayTPS: Double { tps_pct.isFinite ? tps_pct : tps }
    var displayBattery: Double { battery_v.isFinite ? battery_v : vbatt }
}

extension Double {
    var display0: String { isFinite ? String(format: "%.0f", self) : "--" }
    var display1: String { isFinite ? String(format: "%.1f", self) : "--" }
    var display2: String { isFinite ? String(format: "%.2f", self) : "--" }
}
