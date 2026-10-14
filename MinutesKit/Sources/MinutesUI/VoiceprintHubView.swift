#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesSpeakerID

@available(macOS 15.0, iOS 18.0, *)
public struct VoiceprintHubView: View {
    public let store: MinutesStore
    @State public var voiceprints: [Voiceprint] = []
    @State public var people: [Person] = []
    @State public var clusters: [SpeakerCluster] = []
    @State public var utterances: [Utterance] = []
    @State public var selectedVoiceprintId: String? = nil
    
    // Merge State
    @State private var showingMergeSheet = false
    @State private var mergeSourceClusterIds: Set<String> = []
    @State private var mergeTargetName: String = ""
    
    // Split State
    @State private var showingSplitSheet = false
    @State private var splitClusterId: String = ""
    @State private var splitTimestamp: Double = 60.0
    
    // Delete Confirmation
    @State private var voiceprintToDelete: Voiceprint? = nil
    @State private var showingDeleteAlert = false
    
    // Cosine Tester State
    @State private var testVectorAIndex: Int = 0
    @State private var testVectorBIndex: Int = 1
    @State private var testSamplePreset: String = "Baritone Reference"
    @State private var customTestVector: [Float] = []
    
    private let clusterManager = ClusterManager()
    private let meetingId: String?
    
    public init(
        store: MinutesStore,
        meetingId: String? = nil,
        voiceprints: [Voiceprint] = [],
        people: [Person] = [],
        clusters: [SpeakerCluster] = [],
        utterances: [Utterance] = []
    ) {
        self.store = store
        self.meetingId = meetingId
        self._voiceprints = State(initialValue: voiceprints)
        self._people = State(initialValue: people)
        self._clusters = State(initialValue: clusters)
        self._utterances = State(initialValue: utterances)
    }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("🧠")
                                .font(.title2)
                            Text("Speaker Review & Voiceprint Hub")
                                .font(.title2.bold())
                                .foregroundStyle(MinutesTheme.text)
                        }
                        Text("256-dimensional WeSpeaker embedding centroids, cluster fine-tuning, and cosine similarity testing.")
                            .font(.subheadline)
                            .foregroundStyle(MinutesTheme.muted)
                    }
                    Spacer()
                    
                    HStack(spacing: 10) {
                        Button(action: {
                            if clusters.count >= 2 {
                                mergeSourceClusterIds = Set(clusters.prefix(2).map { $0.id })
                                mergeTargetName = clusters.first?.label ?? "Merged Speaker"
                                showingMergeSheet = true
                            }
                        }) {
                            Label("Merge Clusters", systemImage: "arrow.triangle.merge")
                        }
                        .buttonStyle(.bordered)
                        .disabled(clusters.count < 2)
                        
                        Button(action: {
                            if let first = clusters.first {
                                splitClusterId = first.id
                                splitTimestamp = max(10.0, first.speechSeconds / 2.0)
                                showingSplitSheet = true
                            }
                        }) {
                            Label("Split Cluster", systemImage: "arrow.triangle.branch")
                        }
                        .buttonStyle(.bordered)
                        .disabled(clusters.isEmpty)
                    }
                }
                
                // Centroid Visualizer (2D Projection Map & Spectrum)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "circle.hexagongrid.fill")
                            .foregroundStyle(MinutesTheme.purple)
                        Text("CENTROID PROJECTION & EMBEDDING DENSITY")
                            .font(.caption.bold())
                            .foregroundStyle(MinutesTheme.purple)
                        Spacer()
                        Text("Model: WeSpeaker ResNet34 (256-dim)")
                            .font(.caption)
                            .foregroundStyle(MinutesTheme.muted)
                    }
                    
                    HStack(alignment: .top, spacing: 20) {
                        // 2D Projection Map
                        VStack(alignment: .leading, spacing: 8) {
                            Text("2D Centroid Cluster Map")
                                .font(.caption.bold())
                                .foregroundStyle(MinutesTheme.muted)
                            
                            centroid2DScatterMap
                                .frame(height: 220)
                                .frame(maxWidth: .infinity)
                                .background(MinutesTheme.cardHover)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(MinutesTheme.border, lineWidth: 1)
                                )
                        }
                        
                        // Embedding Spectrum
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Feature Spectrum (16-Bin Magnitude Density)")
                                .font(.caption.bold())
                                .foregroundStyle(MinutesTheme.muted)
                            
                            centroidSpectrumView
                                .frame(height: 220)
                                .frame(maxWidth: .infinity)
                                .background(MinutesTheme.cardHover)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(MinutesTheme.border, lineWidth: 1)
                                )
                        }
                    }
                }
                .padding(20)
                .minutesCard()
                
                // Enrolled Voiceprints & Clusters
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .foregroundStyle(MinutesTheme.primary)
                        Text("ENROLLED VOICEPRINTS & ACTIVE CLUSTERS (\(activeVectorsCount))")
                            .font(.caption.bold())
                            .foregroundStyle(MinutesTheme.primary)
                        Spacer()
                    }
                    
                    if voiceprints.isEmpty && clusters.isEmpty {
                        Text("No enrolled voiceprints or clusters found in the local database.")
                            .font(.subheadline)
                            .foregroundStyle(MinutesTheme.muted)
                            .padding(.vertical, 12)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(clusters) { cluster in
                                clusterCard(cluster)
                            }
                            ForEach(voiceprints) { vp in
                                voiceprintCard(vp)
                            }
                        }
                    }
                }
                .padding(20)
                .minutesCard()
                
                // Cosine Distance & Similarity Testing Tool
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "ruler.fill")
                            .foregroundStyle(MinutesTheme.emerald)
                        Text("COSINE DISTANCE & SIMILARITY TEST TOOL")
                            .font(.caption.bold())
                            .foregroundStyle(MinutesTheme.emerald)
                        Spacer()
                        Text("VectorMath.cosineSimilarity(a, b)")
                            .font(.caption.monospaced())
                            .foregroundStyle(MinutesTheme.muted)
                    }
                    
                    cosineDistanceTestHarness
                }
                .padding(20)
                .minutesCard()
            }
            .padding(24)
        }
        .background(MinutesTheme.bg)
        .onAppear {
            refreshData()
        }
        .sheet(isPresented: $showingMergeSheet) {
            mergeSheetView
        }
        .sheet(isPresented: $showingSplitSheet) {
            splitSheetView
        }
        .alert("Delete Voiceprint?", isPresented: $showingDeleteAlert, presenting: voiceprintToDelete) { vp in
            Button("Delete", role: .destructive) {
                do {
                    try store.deleteVoiceprint(id: vp.id)
                    refreshData()
                } catch {
                    print("Delete failed: \(error)")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { vp in
            let personName = people.first(where: { $0.id == vp.personId })?.displayName ?? "Speaker"
            Text("Are you sure you want to delete the voiceprint for \(personName)? This will remove its 256-dim embedding vector.")
        }
    }
    
    private var activeVectorsCount: Int {
        voiceprints.count + clusters.count
    }
    
    // MARK: - 2D Projection Scatter Map
    
    private var centroid2DScatterMap: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cx = w / 2
            let cy = h / 2
            
            ZStack {
                // Coordinate grid lines
                Path { path in
                    path.move(to: CGPoint(x: 0, y: cy))
                    path.addLine(to: CGPoint(x: w, y: cy))
                    path.move(to: CGPoint(x: cx, y: 0))
                    path.addLine(to: CGPoint(x: cx, y: h))
                }
                .stroke(MinutesTheme.border.opacity(0.8), lineWidth: 1)
                
                // Concentric distance rings
                Circle()
                    .stroke(MinutesTheme.border.opacity(0.4), lineWidth: 1)
                    .frame(width: min(w, h) * 0.45, height: min(w, h) * 0.45)
                Circle()
                    .stroke(MinutesTheme.border.opacity(0.4), lineWidth: 1)
                    .frame(width: min(w, h) * 0.85, height: min(w, h) * 0.85)
                
                // Plot cluster centroids
                ForEach(clusters) { c in
                    let coords = VectorMath.project2D(c.centroid)
                    let ptX = cx + CGFloat(coords.x) * (w * 0.4)
                    let ptY = cy - CGFloat(coords.y) * (h * 0.4)
                    
                    VStack(spacing: 2) {
                        Circle()
                            .fill(MinutesTheme.primary)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                            .shadow(color: MinutesTheme.primary.opacity(0.5), radius: 6)
                        Text(c.label)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(MinutesTheme.text)
                    }
                    .position(x: ptX, y: ptY)
                }
                
                // Plot enrolled voiceprints
                ForEach(voiceprints) { vp in
                    let coords = VectorMath.project2D(vp.vector)
                    let ptX = cx + CGFloat(coords.x) * (w * 0.4)
                    let ptY = cy - CGFloat(coords.y) * (h * 0.4)
                    let name = people.first(where: { $0.id == vp.personId })?.displayName ?? "Enrolled"
                    
                    VStack(spacing: 2) {
                        Circle()
                            .fill(MinutesTheme.emerald)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                            .shadow(color: MinutesTheme.emerald.opacity(0.5), radius: 6)
                        Text(name)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(MinutesTheme.muted)
                    }
                    .position(x: ptX, y: ptY)
                }
            }
        }
    }
    
    // MARK: - 16-Bin Magnitude Spectrum
    
    private var centroidSpectrumView: some View {
        let activeVector: [Float] = clusters.first?.centroid ?? voiceprints.first?.vector ?? []
        let bins = VectorMath.binFeatures(activeVector, bins: 16)
        
        return VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<16, id: \.self) { i in
                    let val = i < bins.count ? CGFloat(bins[i]) : 0.0
                    let heightRatio = min(1.0, max(0.05, val * 8.0))
                    
                    VStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [MinutesTheme.primary, MinutesTheme.purple],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: max(6, heightRatio * 140))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            
            HStack {
                Text("Low Band (0-64)")
                    .font(.system(size: 9))
                    .foregroundStyle(MinutesTheme.muted)
                Spacer()
                Text("Mid Band (64-192)")
                    .font(.system(size: 9))
                    .foregroundStyle(MinutesTheme.muted)
                Spacer()
                Text("High Band (192-256)")
                    .font(.system(size: 9))
                    .foregroundStyle(MinutesTheme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
    
    // MARK: - Cluster Card
    
    @ViewBuilder
    private func clusterCard(_ c: SpeakerCluster) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.label)
                        .font(.headline)
                        .foregroundStyle(MinutesTheme.text)
                    Text("Cluster ID: \(c.id)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(MinutesTheme.muted)
                }
                Spacer()
                Text(c.assignment.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(MinutesTheme.primary.opacity(0.15))
                    .foregroundStyle(MinutesTheme.primary)
                    .clipShape(Capsule())
            }
            
            HStack(spacing: 16) {
                metricItem(title: "Speech Time", value: String(format: "%.1fs", c.speechSeconds))
                metricItem(title: "Dimension", value: "\(c.centroid.count)-dim")
                metricItem(title: "Confidence", value: String(format: "%.2f", c.confidence))
            }
        }
        .padding(14)
        .background(MinutesTheme.cardHover)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    // MARK: - Voiceprint Card
    
    @ViewBuilder
    private func voiceprintCard(_ vp: Voiceprint) -> some View {
        let person = people.first(where: { $0.id == vp.personId })
        let name = person?.displayName ?? "Enrolled Voice"
        
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(MinutesTheme.text)
                    Text("VP ID: \(vp.id)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(MinutesTheme.muted)
                }
                Spacer()
                
                Button(action: {
                    voiceprintToDelete = vp
                    showingDeleteAlert = true
                }) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)
            }
            
            HStack(spacing: 16) {
                metricItem(title: "L2 Norm", value: String(format: "%.3f", VectorMath.l2Norm(vp.vector)))
                metricItem(title: "Dimension", value: "\(vp.dim)-dim")
                metricItem(title: "Enrolled", value: DateFormatter.localizedString(from: vp.createdAt, dateStyle: .short, timeStyle: .none))
            }
        }
        .padding(14)
        .background(MinutesTheme.cardHover)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    @ViewBuilder
    private func metricItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(MinutesTheme.muted)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MinutesTheme.text)
        }
    }
    
    // MARK: - Cosine Distance Tester
    
    private var cosineDistanceTestHarness: some View {
        let allVectors = collectVectors()
        let count = allVectors.count
        
        let safeIdxA = min(testVectorAIndex, max(0, count - 1))
        let safeIdxB = min(testVectorBIndex, max(0, count - 1))
        
        let vecA = count > 0 ? allVectors[safeIdxA].vector : []
        let vecB: [Float]
        if count > 1 {
            vecB = allVectors[safeIdxB].vector
        } else {
            vecB = makePresetVector(testSamplePreset)
        }
        
        let similarity = VectorMath.cosineSimilarity(vecA, vecB)
        let distance = VectorMath.cosineDistance(vecA, vecB)
        
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                // Vector A Selector
                VStack(alignment: .leading, spacing: 4) {
                    Text("REFERENCE VECTOR A")
                        .font(.caption.bold())
                        .foregroundStyle(MinutesTheme.muted)
                    Picker("", selection: $testVectorAIndex) {
                        ForEach(0..<count, id: \.self) { i in
                            Text(allVectors[i].label).tag(i)
                        }
                    }
                    .labelsHidden()
                }
                
                // Vector B Selector
                VStack(alignment: .leading, spacing: 4) {
                    Text("TARGET VECTOR B / SAMPLE")
                        .font(.caption.bold())
                        .foregroundStyle(MinutesTheme.muted)
                    if count > 1 {
                        Picker("", selection: $testVectorBIndex) {
                            ForEach(0..<count, id: \.self) { i in
                                Text(allVectors[i].label).tag(i)
                            }
                        }
                        .labelsHidden()
                    } else {
                        Picker("", selection: $testSamplePreset) {
                            Text("Baritone Reference").tag("Baritone Reference")
                            Text("Tenor Sample").tag("Tenor Sample")
                            Text("Whisper Vector").tag("Whisper Vector")
                            Text("Orthogonal Sample").tag("Orthogonal Sample")
                        }
                        .labelsHidden()
                    }
                }
            }
            
            Divider()
            
            // Results Display
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cosine Similarity")
                        .font(.caption)
                        .foregroundStyle(MinutesTheme.muted)
                    Text(String(format: "%.4f", similarity))
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(similarityColor(similarity))
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cosine Distance (1.0 - Sim)")
                        .font(.caption)
                        .foregroundStyle(MinutesTheme.muted)
                    Text(String(format: "%.4f", distance))
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(MinutesTheme.text)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Match Verdict")
                        .font(.caption)
                        .foregroundStyle(MinutesTheme.muted)
                    Text(verdictText(similarity))
                        .font(.headline)
                        .foregroundStyle(similarityColor(similarity))
                }
            }
            
            // Visual Similarity Gauge Bar
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    let w = geo.size.width
                    let barPos = max(0, min(w, CGFloat((similarity + 1.0) / 2.0) * w))
                    
                    ZStack(alignment: .leading) {
                        // Colored threshold bands
                        HStack(spacing: 0) {
                            Rectangle().fill(Color.red.opacity(0.3)).frame(width: w * 0.65)
                            Rectangle().fill(Color.orange.opacity(0.3)).frame(width: w * 0.15)
                            Rectangle().fill(MinutesTheme.emerald.opacity(0.3)).frame(width: w * 0.20)
                        }
                        .clipShape(Capsule())
                        
                        // Marker
                        Circle()
                            .fill(Color.white)
                            .frame(width: 12, height: 12)
                            .shadow(radius: 3)
                            .offset(x: max(0, barPos - 6))
                    }
                }
                .frame(height: 12)
                
                HStack {
                    Text("-1.0 (Opposite)")
                        .font(.system(size: 9))
                        .foregroundStyle(MinutesTheme.muted)
                    Spacer()
                    Text("0.52 (Suggested)")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.orange)
                    Spacer()
                    Text("0.68 (Auto Match)")
                        .font(.system(size: 9))
                        .foregroundStyle(MinutesTheme.emerald)
                    Spacer()
                    Text("+1.0 (Identical)")
                        .font(.system(size: 9))
                        .foregroundStyle(MinutesTheme.muted)
                }
            }
        }
        .padding(14)
        .background(MinutesTheme.cardHover)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    private func collectVectors() -> [(label: String, vector: [Float])] {
        var items: [(label: String, vector: [Float])] = []
        for c in clusters where !c.centroid.isEmpty {
            items.append((label: "Cluster: \(c.label)", vector: c.centroid))
        }
        for vp in voiceprints where !vp.vector.isEmpty {
            let name = people.first(where: { $0.id == vp.personId })?.displayName ?? "Voiceprint"
            items.append((label: "Enrolled: \(name)", vector: vp.vector))
        }
        return items
    }
    
    private func makePresetVector(_ preset: String) -> [Float] {
        var vec = [Float](repeating: 0.0, count: 256)
        switch preset {
        case "Baritone Reference":
            for i in 0..<256 { vec[i] = Float(sin(Double(i) * 0.05)) }
        case "Tenor Sample":
            for i in 0..<256 { vec[i] = Float(cos(Double(i) * 0.05)) }
        case "Whisper Vector":
            for i in 0..<256 { vec[i] = Float(sin(Double(i) * 0.12)) }
        default:
            for i in 0..<256 { vec[i] = (i % 2 == 0) ? 0.08 : -0.08 }
        }
        return VectorMath.l2Normalize(vec)
    }
    
    private func similarityColor(_ s: Double) -> Color {
        if s >= 0.68 { return MinutesTheme.emerald }
        if s >= 0.52 { return Color.orange }
        return Color.red
    }
    
    private func verdictText(_ s: Double) -> String {
        if s >= 0.68 { return "✓ Match (Confirmed Speaker)" }
        if s >= 0.52 { return "⚡ Suggested Candidate" }
        return "✕ Different Speaker"
    }
    
    // MARK: - Merge Sheet View
    
    private var mergeSheetView: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Select clusters to merge. Their 256-dim embedding centroids will be combined using weighted averaging and L2 normalization.")
                    .font(.subheadline)
                    .foregroundStyle(MinutesTheme.muted)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Target Speaker Name:")
                        .font(.caption.bold())
                    TextField("Speaker Name", text: $mergeTargetName)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select Clusters to Merge:")
                        .font(.caption.bold())
                    ForEach(clusters) { c in
                        Toggle(isOn: Binding(
                            get: { mergeSourceClusterIds.contains(c.id) },
                            set: { on in
                                if on { mergeSourceClusterIds.insert(c.id) }
                                else { mergeSourceClusterIds.remove(c.id) }
                            }
                        )) {
                            Text("\(c.label) (\(String(format: "%.1fs", c.speechSeconds)))")
                        }
                    }
                }
                
                Spacer()
                
                Button("Merge Clusters") {
                    let toMerge = clusters.filter { mergeSourceClusterIds.contains($0.id) }
                    guard toMerge.count >= 2 else { return }
                    
                    let merged = clusterManager.merge(clusters: toMerge, targetName: mergeTargetName)
                    
                    // Remove old clusters and save merged
                    var newClusters = clusters.filter { !mergeSourceClusterIds.contains($0.id) }
                    newClusters.append(merged)
                    clusters = newClusters
                    
                    // Re-attribute utterances
                    for i in 0..<utterances.count {
                        if mergeSourceClusterIds.contains(utterances[i].clusterId) {
                            utterances[i].clusterId = merged.id
                            utterances[i].speakerName = merged.label
                        }
                    }
                    
                    try? store.saveSpeakerClusters(newClusters)
                    try? store.saveUtterances(utterances)
                    for oldId in mergeSourceClusterIds {
                        try? store.deleteSpeakerCluster(id: oldId)
                    }
                    
                    showingMergeSheet = false
                    refreshData()
                }
                .buttonStyle(.borderedProminent)
                .disabled(mergeSourceClusterIds.count < 2 || mergeTargetName.isEmpty)
                .frame(maxWidth: .infinity)
            }
            .padding(24)
            .navigationTitle("Merge Speaker Clusters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingMergeSheet = false }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 380)
    }
    
    // MARK: - Split Sheet View
    
    private var splitSheetView: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Split a cluster into two distinct speakers at a given timestamp boundary.")
                    .font(.subheadline)
                    .foregroundStyle(MinutesTheme.muted)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select Cluster:")
                        .font(.caption.bold())
                    Picker("", selection: $splitClusterId) {
                        ForEach(clusters) { c in
                            Text(c.label).tag(c.id)
                        }
                    }
                    .labelsHidden()
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    let targetCluster = clusters.first(where: { $0.id == splitClusterId })
                    let maxSecs = max(60.0, targetCluster?.speechSeconds ?? 120.0)
                    Text("Split Timestamp: \(String(format: "%.1f", splitTimestamp))s")
                        .font(.caption.bold())
                    Slider(value: $splitTimestamp, in: 0.0...maxSecs, step: 1.0)
                }
                
                Spacer()
                
                Button("Split Cluster") {
                    guard let target = clusters.first(where: { $0.id == splitClusterId }) else { return }
                    let (c1, c2, updatedUtterances) = clusterManager.split(
                        cluster: target,
                        boundaryTimestamp: splitTimestamp,
                        utterances: utterances
                    )
                    
                    var newClusters = clusters.filter { $0.id != target.id }
                    newClusters.append(contentsOf: [c1, c2])
                    clusters = newClusters
                    utterances = updatedUtterances
                    
                    try? store.deleteSpeakerCluster(id: target.id)
                    try? store.saveSpeakerClusters(newClusters)
                    try? store.saveUtterances(updatedUtterances)
                    
                    showingSplitSheet = false
                    refreshData()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .padding(24)
            .navigationTitle("Split Speaker Cluster")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingSplitSheet = false }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 340)
    }
    
    private func refreshData() {
        voiceprints = store.listVoiceprints()
        people = store.listPeople()
        let targetId = meetingId ?? store.listMeetings().first?.id
        if let targetId = targetId {
            clusters = store.listSpeakerClusters(meetingId: targetId)
            utterances = store.listUtterances(meetingId: targetId)
        }
    }
}
#endif
