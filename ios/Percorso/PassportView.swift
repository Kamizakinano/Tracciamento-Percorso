import SwiftUI

/// Passaporto: comuni, province, regioni e stati visitati, con le medaglie.
struct PassportView: View {
    @EnvironmentObject private var passport: PassportStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind: PlaceKind = .comune
    /// Scorri subito all'elenco dei luoghi (usato dagli screenshot).
    var scrollToPlaces = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        counters
                        if passport.pendingTrips > 0 {
                            Label("Analizzo i viaggi: ne mancano \(passport.pendingTrips)…", systemImage: "hourglass")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        Text("Medaglie").font(.title3.weight(.bold))
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(passport.medals) { MedalCard(medal: $0) }
                        }
                        places.id("luoghi")
                    }
                    .padding()
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .onAppear {
                    if scrollToPlaces {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { proxy.scrollTo("luoghi", anchor: .top) }
                    }
                }
            }
            .navigationTitle("Passaporto")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }

    // MARK: - Contatori

    private var counters: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(PlaceKind.allCases) { k in
                let medal = passport.medals.first { $0.id == k.rawValue }
                VStack(alignment: .leading, spacing: 6) {
                    Label(k.plural, systemImage: k.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.accentColor)
                    Text("\(passport.passport.count(k))")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(Color(uiColor: .label))
                    if let medal {
                        ProgressView(value: medal.progress)
                            .tint(.accentColor)
                        Text(medal.next.map { "Prossimo traguardo: \(MedalProgress.format($0))" } ?? "Tutti i traguardi raggiunti")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - Luoghi

    private var places: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Luoghi visitati").font(.title3.weight(.bold))
            Picker("Tipo", selection: $kind) {
                ForEach(PlaceKind.allCases) { Text($0.plural).tag($0) }
            }
            .pickerStyle(.segmented)
            let list = passport.passport.list(kind)
            VStack(spacing: 0) {
                if list.isEmpty {
                    Text("Ancora nessun \(kind.singular): registra un viaggio!")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                }
                ForEach(list) { place in
                    HStack(spacing: 12) {
                        Image(systemName: kind.icon)
                            .foregroundColor(.accentColor)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Color(uiColor: .label))
                            if let parent = place.parent {
                                Text(parent).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Text(place.firstVisit.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    if place.id != list.last?.id {
                        Divider().padding(.leading, 50)
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            Text("La data è quella della prima visita. I nomi dei luoghi sono forniti da Apple.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// Medaglia con livello (bronzo, argento, oro, platino) e progresso verso il prossimo.
struct MedalCard: View {
    let medal: MedalProgress

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(color.gradient)
                    .frame(width: 58, height: 58)
                    .shadow(color: color.opacity(0.4), radius: medal.level == .locked ? 0 : 4)
                Image(systemName: medal.icon)
                    .font(.title2)
                    .foregroundColor(.white)
            }
            Text(medal.title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Color(uiColor: .label))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(medal.level.name)
                .font(.caption.weight(.bold))
                .foregroundColor(medal.level == .locked ? .secondary : color)
            ProgressView(value: medal.progress)
                .tint(color)
            Text(caption)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var caption: String {
        if let next = medal.next {
            return "\(medal.valueText) / \(MedalProgress.format(next)) \(medal.unit)"
        }
        return "\(medal.valueText) \(medal.unit)"
    }

    private var color: Color {
        switch medal.level {
        case .locked: return Color(uiColor: .systemGray3)
        case .bronze: return Color(red: 0.72, green: 0.45, blue: 0.2)
        case .silver: return Color(red: 0.55, green: 0.6, blue: 0.66)
        case .gold: return Color(red: 0.9, green: 0.68, blue: 0.1)
        case .platinum: return Color(red: 0.2, green: 0.62, blue: 0.7)
        }
    }
}
