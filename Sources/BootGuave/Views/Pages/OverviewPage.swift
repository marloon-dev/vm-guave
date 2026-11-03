import Charts
import SwiftUI

struct OverviewPage: View {
    @Environment(VMLibrary.self) private var library
    private let monitor = HostMonitor.shared
    private let activity = ActivityLog.shared
    private let router = AppRouter.shared
    @State private var range: ChartRange = .day
    @State private var showingAllActivity = false

    enum ChartRange: String, CaseIterable, Identifiable {
        case hour, day
        var id: String { rawValue }
        var title: LocalizedStringKey { self == .hour ? "Última hora" : "Últimas 24 horas" }
        var seconds: TimeInterval { self == .hour ? 3600 : 24 * 3600 }
    }

    private var runningCount: Int {
        library.configs.filter { library.runner(for: $0.id)?.state.isActive == true }.count
    }

    var body: some View {
        PageScroll {
            PageHeader("Visão Geral", subtitle: "Resumo do seu ambiente virtual.") {
                Button { router.newVM() } label: {
                    Label("Nova VM", systemImage: "plus")
                }
                .buttonStyle(GuaveButtonStyle(large: true))
            }

            statCards

            // Lado a lado na janela larga; um embaixo do outro na estreita.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    // idealWidth limita o que o ViewThatFits mede (o aviso sem dados é uma frase longa).
                    usageChart
                        .frame(minWidth: 460, idealWidth: 460, maxWidth: .infinity)
                    systemResources
                        .frame(width: 320)
                }
                VStack(spacing: 20) {
                    usageChart
                    systemResources
                }
            }

            recentActivity
        }
        .sheet(isPresented: $showingAllActivity) { AllActivitySheet() }
    }

    // MARK: Cartões

    private var statCards: some View {
        let total = library.configs.count
        let usedGB = Double(monitor.memoryUsedBytes) / 1_073_741_824
        let totalGB = Double(monitor.memoryTotalBytes) / 1_073_741_824
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
            StatCard(symbol: "cube", tint: Brand.green, title: "Máquinas virtuais",
                     value: "\(total)", detail: String(localized: "Total no ambiente"))
            StatCard(symbol: "play.fill", tint: Brand.green, title: "Em execução",
                     value: "\(runningCount)",
                     detail: total == 0 ? nil : String(localized: "\(Int((Double(runningCount) / Double(total) * 100).rounded()))% do total"))
            StatCard(symbol: "cpu", tint: Brand.pink, title: "CPU utilizada",
                     value: monitor.cpu.formatted(.percent.precision(.fractionLength(0))),
                     detail: String(localized: "\((monitor.cpu * Double(monitor.coreCount)).formatted(.number.precision(.fractionLength(1)))) de \(monitor.coreCount) núcleos"))
            StatCard(symbol: "memorychip", tint: Brand.pink, title: "Memória utilizada",
                     value: "\(Int(usedGB.rounded())) GB", unit: "/ \(Int(totalGB.rounded())) GB",
                     detail: String(localized: "\(monitor.memoryFraction.formatted(.percent.precision(.fractionLength(0)))) de uso"))
        }
    }

    // MARK: Gráfico

    private var chartSamples: [UsageSample] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        return monitor.history.filter { $0.date >= cutoff }
    }

    private var usageChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Text("Uso de recursos")
                    .font(.title3.weight(.bold))
                    .fixedSize()
                legendDot(Brand.pink, "CPU")
                legendDot(Brand.green, "Memória")
                Spacer(minLength: 8)
                Picker("Período", selection: $range) {
                    ForEach(ChartRange.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if chartSamples.count < 2 {
                Text("O gráfico aparece depois de alguns minutos com o app aberto. O VM Guave mede o uso do Mac inteiro, que inclui as VMs ligadas.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 190, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                Chart {
                    ForEach(chartSamples, id: \.date) { sample in
                        AreaMark(x: .value("Hora", sample.date), y: .value("Uso", sample.memory), series: .value("Série", "mem"))
                            .foregroundStyle(LinearGradient(colors: [Brand.green.opacity(0.35), Brand.green.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Hora", sample.date), y: .value("Uso", sample.memory), series: .value("Série", "mem"))
                            .foregroundStyle(Brand.green)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                            .interpolationMethod(.catmullRom)
                        AreaMark(x: .value("Hora", sample.date), y: .value("Uso", sample.cpu), series: .value("Série", "cpu"))
                            .foregroundStyle(LinearGradient(colors: [Brand.pink.opacity(0.35), Brand.pink.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Hora", sample.date), y: .value("Uso", sample.cpu), series: .value("Série", "cpu"))
                            .foregroundStyle(Brand.pink)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                            .interpolationMethod(.catmullRom)
                    }
                }
                .chartYScale(domain: 0...1)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 0.25, 0.5, 0.75, 1]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text(v.formatted(.percent.precision(.fractionLength(0)))) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .frame(height: 190)
            }
        }
        .guaveCard()
    }

    private func legendDot(_ color: Color, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(title).font(.callout).fixedSize()
        }
    }

    // MARK: Recursos do sistema

    private var systemResources: some View {
        let usedGB = Double(monitor.memoryUsedBytes) / 1_073_741_824
        let totalGB = Double(monitor.memoryTotalBytes) / 1_073_741_824
        return VStack(alignment: .leading, spacing: 16) {
            Text("Recursos do sistema").font(.title3.weight(.bold))
            HStack(spacing: 22) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: 14)
                    Circle()
                        .trim(from: 0, to: max(0.01, monitor.cpu))
                        .stroke(Brand.green, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.6), value: monitor.cpu)
                    VStack(spacing: 0) {
                        Text(monitor.cpu.formatted(.percent.precision(.fractionLength(0))))
                            .font(.system(size: 24, weight: .bold))
                            .monospacedDigit()
                        Text("CPU").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 118, height: 118)
                VStack(alignment: .leading, spacing: 14) {
                    resourceLine(Brand.green, String(localized: "\((monitor.cpu * Double(monitor.coreCount)).formatted(.number.precision(.fractionLength(1)))) de \(monitor.coreCount) núcleos"))
                    resourceLine(Brand.pink, String(localized: "\(Int(usedGB.rounded())) GB de \(Int(totalGB.rounded())) GB"))
                    resourceLine(.secondary, String(localized: "\(Int(max(0, totalGB - usedGB).rounded())) GB livres"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .guaveCard()
    }

    private func resourceLine(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 11, height: 11)
            Text(text).font(.callout).monospacedDigit()
        }
    }

    // MARK: Atividade

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Atividade recente").font(.title3.weight(.bold))
                Spacer()
                if activity.entries.count > 5 {
                    Button { showingAllActivity = true } label: {
                        HStack(spacing: 4) {
                            Text("Ver tudo")
                            Image(systemName: "arrow.right")
                        }
                        .foregroundStyle(Brand.green)
                    }
                    .buttonStyle(.plain)
                    .guaveHover(.text)
                }
            }
            .padding(.bottom, 10)
            if activity.entries.isEmpty {
                Text("Nada por aqui ainda. Iniciar, desligar, criar e importar VMs aparece nesta lista.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(activity.entries.prefix(5))) { entry in
                    Divider()
                    ActivityRow(entry: entry)
                }
            }
        }
        .guaveCard()
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: entry.symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(entry.kind == .settingsSaved ? Color.primary : Brand.ink)
                .frame(width: 28, height: 28)
                .background(Circle().fill(entry.kind == .settingsSaved ? Color.primary.opacity(0.1) : entry.tint))
            Group {
                if entry.subject.isEmpty {
                    Text(entry.phrase)
                } else if entry.isImage {
                    Text("Imagem \(Text(entry.subject).bold()) \(entry.phrase)")
                } else {
                    Text("\(Text(entry.subject).bold())  \(entry.phrase)")
                }
            }
            .font(.callout)
            .lineLimit(1)
            Spacer()
            Text(entry.date.formatted(.relative(presentation: .named)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .help(entry.date.formatted(date: .abbreviated, time: .shortened))
        }
        .padding(.vertical, 9)
    }
}

private struct AllActivitySheet: View {
    private let activity = ActivityLog.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Atividade").font(.title2.weight(.bold))
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            List(activity.entries) { entry in
                ActivityRow(entry: entry)
            }
        }
        .frame(width: 620, height: 520)
    }
}
