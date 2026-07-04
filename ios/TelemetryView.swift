import SwiftUI

struct TelemetryView: View {
    @StateObject private var receiver = UDPReceiver()

    var body: some View {
        let t = receiver.telemetry

        ZStack {
            LinearGradient(colors: [Color.black, Color(red: 0.03, green: 0.05, blue: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dominar 400 TFT")
                                .font(.system(size: 28, weight: .black, design: .rounded))
                                .textCase(.uppercase)
                            Text(receiver.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(t.source.uppercased())
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.08), in: Capsule())
                    }
                    .padding(.horizontal)

                    TFTCluster(t: t)
                        .frame(maxWidth: 1000)
                        .padding(.horizontal)

                    MetricGrid(t: t)
                        .padding(.horizontal)
                }
                .padding(.vertical, 14)
            }
        }
        .onAppear { receiver.start() }
        .onDisappear { receiver.stop() }
    }
}

struct TFTCluster: View {
    var t: Telemetry

    var body: some View {
        ZStack {
            ClusterShape()
                .fill(LinearGradient(colors: [Color(red: 0.08, green: 0.11, blue: 0.15), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(ClusterShape().stroke(.white.opacity(0.16), lineWidth: 1))

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    FuelBars(fuel: t.fuel_pct)
                        .frame(width: 170, height: 28)
                    Spacer()
                }
                .padding(.top, 20)

                ZStack {
                    RPMBand(rpm: t.rpm)
                        .padding(.horizontal, 22)
                        .padding(.top, 2)

                    HStack(alignment: .center) {
                        Spacer()
                        HStack(alignment: .lastTextBaseline, spacing: 8) {
                            Text(t.displaySpeed.display0)
                                .font(.system(size: 100, weight: .black, design: .rounded))
                                .italic()
                                .monospacedDigit()
                            Text("km/h")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                        }
                        Spacer()
                        Text(t.gear)
                            .font(.system(size: 66, weight: .black, design: .rounded))
                            .foregroundStyle(Color(red: 0.79, green: 1.0, blue: 0.45))
                            .frame(width: 88, height: 72)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
                        Spacer().frame(width: 28)
                    }
                    .padding(.top, 60)
                }

                Spacer()

                HStack(alignment: .bottom) {
                    Text("\(t.ambient_c.display0) deg C")
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                    Spacer()
                    HStack(spacing: 8) {
                        StatusTag(label: "MIL", on: t.mil_on)
                        StatusTag(label: "FAN", on: t.fan_on)
                        StatusTag(label: "DTC", on: t.dtc_count > 0)
                    }
                    Spacer()
                    Text(currentTimeString())
                        .font(.system(size: 27, weight: .medium, design: .rounded))
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 18)
            }
        }
        .aspectRatio(2.12, contentMode: .fit)
        .shadow(color: .black.opacity(0.55), radius: 28, y: 18)
    }

    private func currentTimeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }
}

struct RPMBand: View {
    var rpm: Double
    private var fraction: Double { max(0, min(1, rpm.isFinite ? rpm / 10000.0 : 0)) }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 0) {
                ForEach(3...10, id: \.self) { value in
                    Text("\(value)")
                        .font(.system(size: 25, weight: .black, design: .rounded))
                        .italic()
                        .foregroundStyle(value >= 9 ? .red : .white)
                        .frame(maxWidth: .infinity)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(Color(red: 0.78, green: 0.90, blue: 0.86).opacity(0.85))
                        .frame(width: proxy.size.width * fraction)
                    HStack(spacing: 0) {
                        ForEach(0..<32, id: \.self) { i in
                            Rectangle()
                                .fill(.black.opacity(i % 4 == 0 ? 0.38 : 0.16))
                                .frame(width: 1)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    HStack {
                        Spacer()
                        Rectangle().fill(.red.opacity(0.9)).frame(width: proxy.size.width * 0.18)
                    }
                }
            }
            .frame(height: 42)
            HStack {
                Text("RPM")
                    .font(.caption.bold())
                Text("x1000")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

struct FuelBars: View {
    var fuel: Double
    var body: some View {
        let count = Int(round(max(0, min(100, fuel.isFinite ? fuel : 70)) / 100 * 9))
        HStack(spacing: 4) {
            Text("F")
                .font(.headline.bold())
            ForEach(0..<9, id: \.self) { i in
                Rectangle()
                    .fill(i < count ? (fuel < 18 ? Color.orange : Color.white) : Color.white.opacity(0.16))
                    .frame(width: 10, height: 22)
                    .rotationEffect(.degrees(12))
            }
        }
    }
}

struct MetricGrid: View {
    var t: Telemetry
    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            MetricCard(title: "RPM", value: t.rpm.display0, unit: "rpm")
            MetricCard(title: "Speed", value: t.displaySpeed.display0, unit: "km/h")
            MetricCard(title: "Throttle", value: t.displayTPS.display1, unit: "%")
            MetricCard(title: "Coolant", value: t.displayCoolant.display1, unit: "deg C")
            MetricCard(title: "IAT", value: t.displayIAT.display1, unit: "deg C")
            MetricCard(title: "MAP", value: t.displayMAP.display1, unit: "kPa")
            MetricCard(title: "Battery", value: t.displayBattery.display2, unit: "V")
            MetricCard(title: "Lambda", value: t.lambda.display2, unit: "")
            MetricCard(title: "AFR", value: t.afr.display1, unit: ":1")
            MetricCard(title: "Ignition", value: t.ignition_deg.display1, unit: "deg")
            MetricCard(title: "Injector", value: t.injector_ms.display2, unit: "ms")
            MetricCard(title: "Load", value: t.engine_load_pct.display1, unit: "%")
            MetricCard(title: "Fuel rate", value: t.fuel_rate_lph.display2, unit: "L/h")
            MetricCard(title: "Range", value: t.range_km.display0, unit: "km")
            MetricCard(title: "Oil temp", value: t.oil_temp_c.display1, unit: "deg C")
            MetricCard(title: "DTC", value: "\(t.dtc_count)", unit: "")
        }
    }
}

struct MetricCard: View {
    var title: String
    var value: String
    var unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .monospacedDigit()
                Text(unit)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct StatusTag: View {
    var label: String
    var on: Bool

    var body: some View {
        Text(label)
            .font(.caption2.bold())
            .foregroundStyle(on ? .black : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(on ? Color.yellow : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct ClusterShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.24))
        p.closeSubpath()
        return p
    }
}

#Preview {
    TelemetryView()
}
