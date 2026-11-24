import SwiftUI

private enum Palette {
    static let page = Color(red: 0.83, green: 0.83, blue: 0.83)
    static let panel = Color(red: 0.79, green: 0.65, blue: 0.65)
    static let startRow = Color(red: 0.49, green: 0.96, blue: 0.36)
    static let roundRow = Color(red: 0.29, green: 0.55, blue: 0.96)
    static let plus = Color(red: 0.49, green: 0.96, blue: 0.36)
    static let minus = Color(red: 0.25, green: 0.66, blue: 0.96)
    static let picked = Color.yellow
    static let current = Color.red
}

struct ContentView: View {
    @EnvironmentObject private var game: Game
    @FocusState private var focus: Field?
    @State private var confirmNewGame = false
    @State private var showGameOver = false
    @State private var askSaveName = false
    @State private var saveName = ""
    @State private var showOpen = false
    @State private var note: String?
    @State private var counting: PipTarget?

    /// The player whose pips the camera is counting.
    struct PipTarget: Identifiable { let id: UUID; let name: String }

    enum Field: Hashable { case name(UUID), base(UUID), entry(UUID) }

    var body: some View {
        GeometryReader { geo in
            sheet(geo.size)
        }
        // A tap anywhere that isn't a field or button puts the keyboard away.
        .contentShape(Rectangle())
        .onTapGesture { focus = nil }
        .background(Palette.page.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let note {
                Text(note)
                    .font(.headline)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 30)
                    .transition(.opacity)
            }
        }
        .onChange(of: focus) { game.tidyRows() }
        .alert("Start a new match?", isPresented: $confirmNewGame) {
            Button("New Match", role: .destructive) { game.newGame() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(game.state.saveName.map { "\"\($0)\" stays saved as of its last round." }
                 ?? "This match hasn't been saved; its players and scores are cleared.")
        }
        .alert("Save match as", isPresented: $askSaveName) {
            TextField("Name", text: $saveName)
                .textInputAutocapitalization(.words)
            Button("Save") {
                game.save(as: saveName)
                flash("Saved \"\(saveName.trimmingCharacters(in: .whitespaces))\"")
            }
            .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("From now on it's saved after every round.")
        }
        .alert("Game over", isPresented: $showGameOver) {
            Button("OK", role: .cancel) {}
        } message: {
            if let w = game.winners {
                Text("\(ListFormatter.localizedString(byJoining: w.names)) \(w.names.count > 1 ? "tie" : "wins") with \(w.score).")
            }
        }
        .sheet(isPresented: $showOpen) {
            OpenSheet().environmentObject(game)
        }
        .fullScreenCover(item: $counting) { target in
            PipCountView(playerName: target.name, onUse: { points in
                if let i = game.state.players.firstIndex(where: { $0.id == target.id }) {
                    game.state.players[i].entry = String(points)
                    game.tidyRows()
                }
                counting = nil
            }, onCancel: { counting = nil })
        }
    }

    /// One column — title, tiles, players, buttons — scaled to the screen's width,
    /// so turning the phone sideways makes everything bigger (and it scrolls).
    private func sheet(_ size: CGSize) -> some View {
        // On iPad the full width would make the sheet taller than the screen.
        let cap: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 820 : 1100
        let width = min(size.width - 16, cap)
        return ScrollView {
            VStack(spacing: 0) {
                title(width: width)
                tileRows(width: width)
                players(width: width - 16)
                buttonBar(width: width - 16)
                    .padding(.top, 4)
                    .padding(.bottom, 14)
            }
            .frame(width: width)
            .background(panel)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// The rose card behind everything.
    private var panel: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(Palette.panel)
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.black, lineWidth: 1))
    }

    private func title(width: CGFloat) -> some View {
        Text("Domin-Uno")
            .font(.system(size: width * 0.085, weight: .regular))
            .padding(.top, 8)
    }

    private func tileRows(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            startRow(width: width - 16)
            roundRow(width: width - 16)
        }
        .border(Color.black, width: 1)
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }

    private func players(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach($game.state.players) { $row in
                PlayerLine(row: $row,
                           name: Binding(get: { row.name }, set: { game.setName(row.id, $0) }),
                           width: width, focus: $focus,
                           onCount: { focus = nil; counting = PipTarget(id: row.id, name: row.name) })
                    .padding(.bottom, width * 0.035)
            }
        }
    }

    // MARK: Green row — the double that starts this round (12 down to the double-blank)

    private func startRow(width: CGFloat) -> some View {
        let cell = cellSize(width)
        let s = game.state
        return HStack(spacing: gap(width)) {
            ForEach((0..<GameState.rounds).reversed(), id: \.self) { pips in
                let picked = s.starts.contains(pips)
                let isCurrent = s.currentRound.map { s.starts[$0] == pips } ?? false
                Button { game.pickStart(pips) } label: {
                    DominoFace(pips: pips)
                        .frame(width: cell, height: cell)
                        .overlay(highlight(picked: picked, current: isCurrent))
                }
                .buttonStyle(.plain)
                .disabled(s.isOver)
                .accessibilityLabel(pips == 0 ? "Start with double blank" : "Start with double \(pips)")
            }
        }
        .padding(.vertical, 5)
        .frame(width: width)
        .background(Palette.startRow)
    }

    // MARK: Blue row — rounds finished; tap the red-outlined round to finish it

    private func roundRow(width: CGFloat) -> some View {
        let cell = cellSize(width)
        let s = game.state
        return HStack(spacing: gap(width)) {
            ForEach(1...GameState.rounds, id: \.self) { round in
                let isCurrent = round == s.roundsDone + 1
                Button {
                    guard isCurrent else { return }
                    focus = nil
                    finishRound()
                } label: {
                    DominoFace(pips: round <= 12 ? round : 0)
                        .frame(width: cell, height: cell)
                        .overlay(highlight(picked: round <= s.roundsDone, current: isCurrent))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if round == s.roundsDone {
                        Button("Undo Round \(round)", systemImage: "arrow.uturn.backward") { game.undoRound() }
                    }
                }
                .accessibilityLabel(isCurrent ? "Finish round \(round)" : "Round \(round)")
            }
        }
        .padding(.vertical, 5)
        .frame(width: width)
        .background(Palette.roundRow)
    }

    // MARK: New · Open · Save

    private func buttonBar(width: CGFloat) -> some View {
        HStack(spacing: width * 0.04) {
            barButton("New", width: width) { focus = nil; confirmNewGame = true }
            barButton("Open", width: width) { focus = nil; showOpen = true }
            barButton("Save", width: width) {
                focus = nil
                if let name = game.state.saveName {
                    game.save(as: name)
                    flash("Saved \"\(name)\"")
                } else {
                    saveName = ""
                    askSaveName = true
                }
            }
        }
    }

    private func barButton(_ title: String, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: width * 0.055))
                .foregroundStyle(.black)
                .frame(width: width * 0.28, height: width * 0.11)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func finishRound() {
        game.nextRound()
        if game.state.isOver { showGameOver = true }
    }

    private func flash(_ text: String) {
        withAnimation { note = text }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { if note == text { note = nil } }
        }
    }

    private func cellSize(_ width: CGFloat) -> CGFloat {
        let n = CGFloat(GameState.rounds)
        return (width - 8 - gap(width) * (n - 1)) / n
    }

    private func gap(_ width: CGFloat) -> CGFloat { max(2, width * 0.008) }

    @ViewBuilder
    private func highlight(picked: Bool, current: Bool) -> some View {
        ZStack {
            if picked {
                RoundedRectangle(cornerRadius: 4).fill(Palette.picked.opacity(0.45))
                RoundedRectangle(cornerRadius: 4).stroke(Palette.picked, lineWidth: 2)
            }
            if current {
                RoundedRectangle(cornerRadius: 4).stroke(Palette.current, lineWidth: 2.5)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The saved matches, one checkmarked to open.
private struct OpenSheet: View {
    @EnvironmentObject private var game: Game
    @Environment(\.dismiss) private var dismiss
    @State private var matches: [SavedMatch] = []
    @State private var selected: String?

    var body: some View {
        NavigationStack {
            List {
                if matches.isEmpty {
                    Text("No saved matches yet.").foregroundStyle(.secondary)
                }
                ForEach(matches) { m in
                    Button { selected = m.name } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected == m.name ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundStyle(selected == m.name ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name).font(.headline)
                                Text(m.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { rows in
                    for i in rows { game.delete(matches[i]) }
                    matches = game.savedMatches()
                    if !matches.contains(where: { $0.name == selected }) { selected = nil }
                }
            }
            .navigationTitle("Open Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") {
                        if let m = matches.first(where: { $0.name == selected }) { game.open(m) }
                        dismiss()
                    }
                    .disabled(selected == nil)
                }
            }
            .onAppear {
                matches = game.savedMatches()
                selected = game.state.saveName.flatMap { n in matches.contains { $0.name == n } ? n : nil }
            }
        }
    }
}

/// Name   (n)  ±  (x)  =  (n+x)
private struct PlayerLine: View {
    @Binding var row: PlayerRow
    @Binding var name: String
    let width: CGFloat
    var focus: FocusState<ContentView.Field?>.Binding
    /// Touch and hold (x) to count this player's pips with the camera.
    var onCount: () -> Void

    var body: some View {
        let unit = width / 9.0
        let height = unit * 1.15
        let font = Font.system(size: height * 0.5)
        HStack(spacing: unit * 0.1) {
            box(TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused(focus, equals: .name(row.id)),
                width: unit * 2.9, height: height, font: font, alignment: .leading)
            box(TextField("", text: digits($row.base), prompt: zero)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused(focus, equals: .base(row.id)),
                width: unit * 1.55, height: height, font: font, alignment: .trailing)
            VStack(spacing: 2) {
                signButton("+", on: !row.minus, color: Palette.plus) { row.minus = false }
                signButton("−", on: row.minus, color: Palette.minus) { row.minus = true }
            }
            .frame(width: unit * 0.55, height: height)
            box(TextField("", text: digits($row.entry), prompt: zero)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused(focus, equals: .entry(row.id)),
                width: unit * 1.55, height: height, font: font, alignment: .trailing)
                // While (x) isn't being typed in: a tap edits it, touch and hold counts pips with the camera.
                .overlay {
                    if focus.wrappedValue != .entry(row.id) {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                LongPressGesture(minimumDuration: 0.5)
                                    .onEnded { _ in onCount() }
                                    .exclusively(before: TapGesture().onEnded {
                                        focus.wrappedValue = .entry(row.id)
                                    }))
                            .accessibilityElement()
                            .accessibilityLabel("Points left in hand")
                            .accessibilityAction { focus.wrappedValue = .entry(row.id) }
                            .accessibilityAction(named: "Count pips with camera", onCount)
                    }
                }
            Text("=").font(font)
            box(Text(String(row.total)),
                width: unit * 1.55, height: height, font: font, alignment: .trailing)
        }
    }

    private func box<V: View>(_ content: V, width: CGFloat, height: CGFloat, font: Font,
                              alignment: Alignment) -> some View {
        content
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .foregroundStyle(.black)
            .padding(.horizontal, 6)
            .frame(width: width, height: height, alignment: alignment)
            .background(Color.white)
            .border(Color.black.opacity(0.7), width: 1)
    }

    private func signButton(_ label: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: width * 0.05, weight: .medium))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(on ? color : Color.white)
                .border(Color.black.opacity(0.7), width: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label == "+" ? "Add" : "Subtract")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// An empty number field shows a plain 0, so typing 7 gives 7 without the field being rewritten.
    private var zero: Text { Text("0").foregroundStyle(Color.black) }

    /// Keeps a number field to digits (pasted text included).
    private func digits(_ text: Binding<String>) -> Binding<String> {
        Binding(get: { text.wrappedValue },
                set: {
                    // Digits only, without leading zeros: typing 5 over the starting 0 gives 5.
                    var d = String($0.filter(\.isNumber).prefix(4))
                    while d.hasPrefix("0") { d.removeFirst() }   // a lone 0 is the empty field
                    text.wrappedValue = d
                })
    }
}

#Preview {
    ContentView().environmentObject(Game())
}
