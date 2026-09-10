export interface ExperimentSample {
  measurement_date: string;
  measurement_phase: string;
  metric_name: string;
  metric_value: number;
  metric_unit: string | null;
  protocol_followed: boolean;
}

export function metricDirection(metric: string): number | null {
  switch (metric.trim().toLowerCase()) {
    case "sleep_quality":
    case "energy":
    case "energy_level":
      return 1;
    case "stress":
    case "stress_level":
    case "fatigue":
    case "pain":
      return -1;
    default:
      // Weight, duration, HRV, etc. have no universal desired direction.
      return null;
  }
}

/** Descriptive within-person comparison. Serial, unrandomized daily observations
 * do not justify an independent-samples p-value or a causal treatment claim. */
export function analyzeExperiment(metric: string, samples: ExperimentSample[]) {
  const primary = samples.filter((sample) =>
    sample.metric_name === metric && Number.isFinite(sample.metric_value) &&
    ["baseline", "intervention"].includes(sample.measurement_phase)
  );
  const included = primary.filter((sample) => sample.protocol_followed);
  const units = new Set(
    included.map((sample) => sample.metric_unit?.trim() ?? ""),
  );
  const coherentUnits = units.size <= 1;
  const baseline = coherentUnits
    ? included.filter((sample) => sample.measurement_phase === "baseline")
      .map((sample) => sample.metric_value)
    : [];
  const intervention = coherentUnits
    ? included.filter((sample) => sample.measurement_phase === "intervention")
      .map((sample) => sample.metric_value)
    : [];
  const mean = (values: number[]) =>
    values.length
      ? values.reduce((sum, value) => sum + value / values.length, 0)
      : null;
  const deviation = (values: number[], average: number | null) =>
    average !== null && values.length > 1
      ? Math.sqrt(
        values.reduce((sum, value) => sum + (value - average) ** 2, 0) /
          (values.length - 1),
      )
      : null;
  const baselineMean = mean(baseline);
  const interventionMean = mean(intervention);
  const baselineSD = deviation(baseline, baselineMean);
  const interventionSD = deviation(intervention, interventionMean);
  const enoughData = baseline.length >= 3 && intervention.length >= 3;
  const delta = baselineMean !== null && interventionMean !== null
    ? interventionMean - baselineMean
    : null;
  const direction = metricDirection(metric);
  const pooledSD = enoughData && baselineSD !== null && interventionSD !== null
    ? Math.sqrt(
      ((baseline.length - 1) * baselineSD ** 2 +
        (intervention.length - 1) * interventionSD ** 2) /
        (baseline.length + intervention.length - 2),
    )
    : null;
  const interpretation = !coherentUnits
    ? "Units differ across observations; comparison is unavailable. Correct the units before comparing phases."
    : !enoughData
    ? `Insufficient data: baseline n=${baseline.length}, intervention n=${intervention.length}. At least 3 protocol-followed observations per phase are required for a descriptive comparison.`
    : `Descriptive comparison for ${metric}: baseline mean ${
      baselineMean!.toFixed(2)
    } (n=${baseline.length}), intervention mean ${
      interventionMean!.toFixed(2)
    } (n=${intervention.length}). Change ${
      delta!.toFixed(2)
    }. This nonrandomized comparison does not establish causation or statistical significance.`;
  // NUMERIC(10,4) schema bounds; never overflow persistence on extreme input.
  const finite = (value: number | null) =>
    value !== null && Number.isFinite(value) && Math.abs(value) < 1_000_000
      ? value
      : null;
  return {
    baseline_mean: finite(baselineMean),
    baseline_std_dev: finite(baselineSD),
    intervention_mean: finite(interventionMean),
    intervention_std_dev: finite(interventionSD),
    effect_size: finite(
      enoughData && pooledSD && delta !== null ? delta / pooledSD : null,
    ),
    p_value: null,
    confidence_interval_lower: null,
    confidence_interval_upper: null,
    significant: null,
    effect_direction: enoughData && direction !== null && delta !== null
      ? delta === 0
        ? "neutral"
        : delta * direction > 0
        ? "positive"
        : "negative"
      : null,
    ai_interpretation: interpretation,
    ai_recommendation:
      "Treat these results as descriptive. Review adherence and other changes before deciding whether to repeat the experiment.",
    compliance_percent: primary.length
      ? included.length / primary.length * 100
      : null,
  };
}
