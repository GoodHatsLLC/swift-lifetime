// © GoodHatsLLC

import Foundation
import Testing

struct DemoRuntimeControllerTests {
  @Test
  @MainActor
  func `boot and shutdown refresh runtime state`() async throws {
    let model = DemoRuntimeController()

    let bootMessage = try await model.boot(policy: .parallelUnordered)

    #expect(bootMessage == "runtime booted with policy: parallelUnordered")
    #expect(model.isLifetimeed)
    #expect(model.activePolicy == .parallelUnordered)
    #expect(model.rootDescription.contains("PaymentGateway"))
    #expect(model.rootDescription.contains("InventorySystem"))
    #expect(model.recentTrace(limit: 1).last?.message == "runtime booted policy=parallelUnordered")

    let shutdownMessage = await model.shutdown()

    #expect(shutdownMessage == "runtime is offline")
    #expect(!model.isLifetimeed)
    #expect(model.rootDescription == "Scope(state: offline)")
    #expect(model.recentTrace(limit: 1).last?.message == "runtime shutdown complete")
  }

  @Test
  @MainActor
  func `checkout records request scoped lifecycle events`() async throws {
    let model = DemoRuntimeController()
    _ = try await model.boot(policy: .serialLIFO)

    let result = try await model.checkout(tenantID: "acme", itemCount: 3, amount: 149.50)

    #expect(result.contains("checkout completed: receipt="))
    #expect(model.paymentMetrics.charges == 1)
    #expect(model.paymentMetrics.refunds == 0)
    #expect(model.inventoryMetrics.committedItems == 3)
    #expect(model.inventoryMetrics.openReservations == 0)

    let trace = model.recentTrace(limit: 20).map(\.message)
    #expect(trace.contains(where: { $0.contains("checkout start tenant=acme") }))
    #expect(trace.contains(where: { $0.contains("checkout success tenant=acme") }))
    #expect(trace.contains(where: { $0.contains("request context destroyed route=/checkout") }))
    #expect(trace.contains(where: { $0.contains("tenant session cancelled tenant=acme") }))

    _ = await model.shutdown()
  }

  @Test
  @MainActor
  func `cancelling import job marks job cancelled and tears down child scope`() async throws {
    let model = DemoRuntimeController()
    _ = try await model.boot(policy: .serialLIFO)

    let jobID = try await model.startImport(tenantID: "acme", dataset: "customers", rows: 24)

    #expect(model.jobs.contains(where: { $0.id == jobID && $0.state == .running }))

    let cancelMessage = try await model.cancelImportJob(id: jobID)

    #expect(cancelMessage == "job \(jobID) cancelled")
    #expect(model.jobs.contains(where: { $0.id == jobID && $0.state == .cancelled }))

    let trace = model.recentTrace(limit: 30).map(\.message)
    #expect(trace.contains(where: { $0.contains("import job started id=\(jobID)") }))
    #expect(
      trace.contains(where: { $0.contains("import cursor destroyed tenant=acme dataset=customers") }
      ),
    )
    #expect(trace.contains(where: { $0.contains("import job cancel requested id=\(jobID)") }))

    _ = await model.shutdown()
  }
}
