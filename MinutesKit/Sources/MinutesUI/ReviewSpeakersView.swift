#if canImport(SwiftUI)
import SwiftUI
import MinutesCore
import MinutesSpeakerID

@available(macOS 15.0, iOS 18.0, *)
public struct ReviewSpeakersView: View {
    public let meeting: Meeting
    @State public var clusters: [SpeakerCluster]
    @State public var attendees: [Person]
    public let onAssign: (String, Person) -> Void
    public let onLockAndEnroll: () -> Void
    
    public init(
        meeting: Meeting,
        clusters: [SpeakerCluster],
        attendees: [Person],
        onAssign: @escaping (String, Person) -> Void,
        onLockAndEnroll: @escaping () -> Void
    ) {
        self.meeting = meeting
        self._clusters = State(initialValue: clusters)
        self._attendees = State(initialValue: attendees)
        self.onAssign = onAssign
        self.onLockAndEnroll = onLockAndEnroll
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Speakers")
                        .font(.title2.bold())
                    Text("Map speaker clusters to meeting attendees. Voiceprints will be enrolled on lock.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onLockAndEnroll) {
                    Label("Lock & Enroll Voiceprints", systemImage: "checkmark.seal.fill")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 10)
            
            // Attendee Chips
            VStack(alignment: .leading, spacing: 8) {
                Text("CALENDAR ATTENDEES")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(attendees) { person in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.blue.opacity(0.8))
                                    .frame(width: 8, height: 8)
                                Text(person.displayName)
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                        }
                    }
                }
            }
            
            Divider()
            
            // Speaker Clusters
            VStack(alignment: .leading, spacing: 12) {
                Text("DETECTED VOICE CLUSTERS")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                
                ForEach(clusters) { cluster in
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cluster.label)
                                .font(.headline)
                            Text(String(format: "%.1f seconds spoken · %d-dim embedding", cluster.speechSeconds, cluster.centroid.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        // Assignment Selector Menu
                        Menu {
                            ForEach(attendees) { person in
                                Button(person.displayName) {
                                    onAssign(cluster.id, person)
                                    if let idx = clusters.firstIndex(where: { $0.id == cluster.id }) {
                                        clusters[idx].label = person.displayName
                                        clusters[idx].assignment = "user"
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(cluster.personId != nil ? cluster.label : "Assign Attendee...")
                                    .font(.subheadline.weight(.medium))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding()
    }
}
#endif
