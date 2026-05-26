import Foundation
import Lifetime

@main
struct LifetimeBenchmarks {
  private struct Benchmark {
    let name: String
    let iterations: Int
    let operation: @Sendable () async throws -> Void
  }

  private struct Measurement {
    let nanosecondsPerIteration: Double
  }

  // Baselines are per-iteration nanoseconds, calibrated against the median
  // of 13 release-mode runs on an Apple Silicon (M-series) Mac with
  // roughly 15% headroom above the median. Combined with the ±20%
  // detection band below, the "slower" trigger sits at median × 1.38 —
  // above the noisiest run observed during calibration. Tight enough to
  // catch real drift without false positives on ordinary machine noise.
  //
  // `withChild.input.createCancelScope` is set at median × 1.20 instead
  // of × 1.15 because its observed tail extends further above the
  // median than the other steady benchmarks (35% vs ≤22%). At these
  // sub-microsecond ops, absolute jitter becomes a larger relative
  // share, so the wider headroom prevents false "slower" flags. The
  // `adopt100Resources` benchmark runs 2000 iterations (rather than 500
  // — see makeBenchmarks) for the same reason: its cancel walk is
  // sensitive to cooperative-pool latency spikes that only smooth out
  // across enough samples.
  private static let baselinesNsPerIteration: [String: Double] = [
    "start.inline.createCancelScope": 2_800,
    "withResource.inline.createCancelScope": 4_200,
    "childFactory.makeCancelScope": 3_900,
    "withChild.input.createCancelScope": 3_700,
    "scope.cancel.adopt100Resources": 68_500,
  ]

  static func main() async {
    do {
      try await run()
    } catch {
      print("LifetimeBenchmarks failed: \(error)")
      Foundation.exit(EXIT_FAILURE)
    }
  }

  private static func run() async throws {
    let benchmarks = makeBenchmarks()

    print("LifetimeBenchmarks")
    print("Metric: nanoseconds per iteration (lower is better).")
    print("Baseline status uses +/-20% tolerance for quick local regression checks.")
    print("")
    print(row("benchmark", "ns/op", "baseline", "delta", "status"))

    for benchmark in benchmarks {
      let measurement = try await measure(benchmark)
      let baseline = baselinesNsPerIteration[benchmark.name]
      let nsPerOp = measurement.nanosecondsPerIteration
      let baselineText = baseline.map(formatNanos) ?? "-"
      let deltaText: String
      let status: String

      if let baseline {
        let delta = ((nsPerOp - baseline) / baseline) * 100
        deltaText = formatPercent(delta)
        if delta > 20 {
          status = "slower"
        } else if delta < -20 {
          status = "faster"
        } else {
          status = "ok"
        }
      } else {
        deltaText = "-"
        status = "new"
      }

      print(
        row(
          benchmark.name,
          formatNanos(nsPerOp),
          baselineText,
          deltaText,
          status
        )
      )
    }
  }

  private static func makeBenchmarks() -> [Benchmark] {
    [
      Benchmark(
        name: "start.inline.createCancelScope",
        iterations: 2_000,
        operation: {
          let scope = Scope.root()
          _ = try await scope.start(launchPolicy: .inline) {
            UUID()
          }
          await scope.cancel()
        }
      ),
      Benchmark(
        name: "withResource.inline.createCancelScope",
        iterations: 2_000,
        operation: {
          let scope = Scope.root()
          _ = try await scope.withResource(
            launchPolicy: .inline,
            create: {
              UUID()
            }
          ) { value in
            value
          }
          await scope.cancel()
        }
      ),
      Benchmark(
        name: "childFactory.makeCancelScope",
        iterations: 2_000,
        operation: {
          let scope = Scope.root()
          let makeChild = try scope.childFactory(name: "BenchChild") {
            (
              input: Int,
              child: Scope
            ) in
            _ = try await child.start("Marker") { input }
            return input
          }
          let child = try await makeChild.make(1)
          await child.cancel()
          await scope.cancel()
        }
      ),
      Benchmark(
        name: "withChild.input.createCancelScope",
        iterations: 2_000,
        operation: {
          let scope = Scope.root()
          _ = try await scope.withChild(
            name: "BenchWithChild",
            input: 1,
            build: { input, child in
              _ = try await child.start("Marker") { input }
              return input
            }
          ) { child in
            child.exports
          }
          await scope.cancel()
        }
      ),
      Benchmark(
        name: "scope.cancel.adopt100Resources",
        // Larger iteration count averages out the occasional cooperative-pool
        // latency spike from back-to-back inline cancel walks. At 500 iters
        // the per-run standard deviation included rare 2-3x outliers; at
        // 2000 iters those spikes are amortized across enough samples to
        // keep run-to-run variance closer to the steady benchmarks.
        iterations: 2_000,
        operation: {
          let scope = Scope.root()
          for _ in 0..<100 {
            try scope.adopt(Resource(value: UUID()))
          }
          await scope.cancel()
        }
      ),
    ]
  }

  private static func measure(_ benchmark: Benchmark) async throws -> Measurement {
    let clock = ContinuousClock()
    let start = clock.now

    for _ in 0..<benchmark.iterations {
      try await benchmark.operation()
    }

    let elapsed = clock.now - start
    let totalNanoseconds =
      (Double(elapsed.components.seconds) * 1_000_000_000)
      + (Double(elapsed.components.attoseconds) / 1_000_000_000)
    let nanosecondsPerIteration = totalNanoseconds / Double(benchmark.iterations)

    return Measurement(
      nanosecondsPerIteration: nanosecondsPerIteration
    )
  }

  private static func row(
    _ benchmark: String,
    _ nsPerOp: String,
    _ baseline: String,
    _ delta: String,
    _ status: String
  ) -> String {
    let columns = [
      pad(benchmark, width: 38, alignLeft: true),
      pad(nsPerOp, width: 12, alignLeft: false),
      pad(baseline, width: 12, alignLeft: false),
      pad(delta, width: 10, alignLeft: false),
      pad(status, width: 8, alignLeft: false),
    ]
    return columns.joined(separator: " ")
  }

  private static func formatNanos(_ value: Double) -> String {
    String(Int(value.rounded()))
  }

  private static func formatPercent(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    let sign = rounded >= 0 ? "+" : ""
    return "\(sign)\(rounded)%"
  }

  private static func pad(_ value: String, width: Int, alignLeft: Bool) -> String {
    guard value.count < width else { return value }
    let padding = String(repeating: " ", count: width - value.count)
    return alignLeft ? value + padding : padding + value
  }
}
