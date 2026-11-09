import AppIntents
import WorkersTelemetry

/// Worker oferecido no editor do widget, listado a partir da pasta do coletor.
struct WorkerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Worker"
    static let defaultQuery = WorkerQuery()
    var id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(WorkerSnapshot(id: id, reading: nil, connection: nil).displayName)") }
}

struct WorkerQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WorkerEntity] { identifiers.map { WorkerEntity(id: $0) } }
    func suggestedEntities() async throws -> [WorkerEntity] { WorkersTelemetry.load().map { WorkerEntity(id: $0.id) } }
}

/// "Editar widget": até quatro posições, cada uma com worker e apelido (regras em `WorkersLayout.arrange`).
struct WorkersWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Workers"
    static let description = IntentDescription("Escolha a ordem dos workers e dê apelidos a eles.")

    @Parameter(title: "1º worker") var worker1: WorkerEntity?
    @Parameter(title: "Apelido do 1º worker") var apelido1: String?
    @Parameter(title: "2º worker") var worker2: WorkerEntity?
    @Parameter(title: "Apelido do 2º worker") var apelido2: String?
    @Parameter(title: "3º worker") var worker3: WorkerEntity?
    @Parameter(title: "Apelido do 3º worker") var apelido3: String?
    @Parameter(title: "4º worker") var worker4: WorkerEntity?
    @Parameter(title: "Apelido do 4º worker") var apelido4: String?

    static var parameterSummary: some ParameterSummary {
        Summary {
            \.$worker1; \.$apelido1
            \.$worker2; \.$apelido2
            \.$worker3; \.$apelido3
            \.$worker4; \.$apelido4
        }
    }

    func apply(to workers: [WorkerSnapshot]) -> [WorkerSnapshot] {
        WorkersLayout.arrange(workers, slots: [(worker1?.id, apelido1), (worker2?.id, apelido2), (worker3?.id, apelido3), (worker4?.id, apelido4)])
    }
}
