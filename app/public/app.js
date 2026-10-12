const currency = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  maximumFractionDigits: 0,
});

const integer = new Intl.NumberFormat("en-US");

const elements = {
  connectionLabel: document.querySelector("#connection-label"),
  versionLabel: document.querySelector("#version-label"),
  serverPill: document.querySelector(".server-pill"),
  revenue: document.querySelector("#revenue-value"),
  orders: document.querySelector("#orders-value"),
  customers: document.querySelector("#customers-value"),
  products: document.querySelector("#products-value"),
  countryBars: document.querySelector("#country-bars"),
  tableList: document.querySelector("#table-list"),
  ordersBody: document.querySelector("#orders-body"),
  updatedAt: document.querySelector("#updated-at"),
  refreshButton: document.querySelector("#refresh-button"),
  pipelineName: document.querySelector("#pipeline-name"),
  pipelineSelector: document.querySelector("#pipeline-selector"),
  pipelineStatus: document.querySelector("#pipeline-status"),
  pipelineLastRun: document.querySelector("#pipeline-last-run"),
  pipelineTrigger: document.querySelector("#pipeline-trigger"),
  pipelineRows: document.querySelector("#pipeline-rows"),
  pipelineDuration: document.querySelector("#pipeline-duration"),
  pipelineStructure: document.querySelector("#pipeline-structure"),
  pipelineStructureSummary: document.querySelector("#pipeline-structure-summary"),
  pipelineSteps: document.querySelector("#pipeline-steps"),
  qualityResults: document.querySelector("#quality-results"),
  pipelineError: document.querySelector("#pipeline-error"),
  runPipelineButton: document.querySelector("#run-pipeline-button"),
  conversionChallengesSection: document.querySelector("#conversion-challenges-section"),
  conversionChallengesSummary: document.querySelector("#conversion-challenges-summary"),
  conversionChallenges: document.querySelector("#conversion-challenges"),
  errorBanner: document.querySelector("#error-banner"),
};

let selectedPipelineKey = "sales-analytics";

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function formatTimestamp(value) {
  if (!value) return "—";
  return new Intl.DateTimeFormat("en-US", {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(new Date(value));
}

function formatDuration(value) {
  if (value === null || value === undefined) return "—";
  if (value < 1000) return `${value} ms`;
  return `${(value / 1000).toFixed(2)} s`;
}

function renderPipelineSelector(pipelines, selectedKey) {
  elements.pipelineSelector.innerHTML = pipelines
    .map((pipeline) => `<option value="${escapeHtml(pipeline.pipelineKey)}">${escapeHtml(pipeline.pipelineName)}</option>`)
    .join("");
  elements.pipelineSelector.value = selectedKey;
}

function renderPipeline(pipeline) {
  elements.pipelineName.textContent = pipeline.name || "Pipeline";
  const run = pipeline.run;
  const status = run?.status || "Waiting";
  const statusClass = status.toLowerCase();

  elements.pipelineStatus.textContent = status;
  elements.pipelineStatus.className = `pipeline-status ${statusClass}`;
  elements.pipelineLastRun.textContent = run ? formatTimestamp(run.completedAt || run.startedAt) : "Waiting for the first run";
  elements.pipelineTrigger.textContent = run?.triggeredBy || "—";
  elements.pipelineRows.textContent = run?.rowsProcessed === null || run?.rowsProcessed === undefined
    ? "—"
    : integer.format(run.rowsProcessed);
  elements.pipelineDuration.textContent = formatDuration(run?.durationMs);
  elements.pipelineError.hidden = !run?.errorMessage;
  elements.pipelineError.textContent = run?.errorMessage ? `Pipeline error: ${run.errorMessage}` : "";

  const statusByStep = new Map(pipeline.steps.map((step) => [step.stepKey, step.status]));
  const dependenciesByStep = pipeline.dependencies.reduce((result, dependency) => {
    const current = result.get(dependency.stepKey) || [];
    current.push(dependency.dependsOnStepKey);
    result.set(dependency.stepKey, current);
    return result;
  }, new Map());
  const layers = pipeline.structure.reduce((result, step) => {
    const current = result.get(step.layerNumber) || { name: step.layerName, steps: [] };
    current.steps.push(step);
    result.set(step.layerNumber, current);
    return result;
  }, new Map());

  elements.pipelineStructureSummary.textContent = `${layers.size} layers · ${pipeline.structure.length} procedures`;

  elements.pipelineStructure.innerHTML = [...layers.entries()]
    .map(([layerNumber, layer], index) => `
      ${index ? '<span class="layer-arrow" aria-hidden="true">→</span>' : ""}
      <div class="pipeline-layer">
        <div class="layer-title"><span>L${layerNumber}</span>${escapeHtml(layer.name)}</div>
        ${layer.steps.map((step) => {
          const stepStatus = String(statusByStep.get(step.stepKey) || "waiting").toLowerCase();
          const dependencies = dependenciesByStep.get(step.stepKey) || [];
          return `
            <div class="structure-node ${stepStatus}">
              <span class="node-state"></span>
              <div>
                <strong>${escapeHtml(step.stepName)}</strong>
                <small>${escapeHtml(step.procedureName)}</small>
                ${dependencies.length ? `<em>after ${dependencies.map(escapeHtml).join(", ")}</em>` : ""}
              </div>
            </div>`;
        }).join("")}
      </div>`)
    .join("");

  elements.pipelineSteps.innerHTML = pipeline.steps.length
    ? pipeline.steps
      .map(
        (step) => `
          <li class="pipeline-step ${String(step.status).toLowerCase()}">
            <span class="step-order">${String(step.stepOrder).padStart(2, "0")}</span>
            <div class="step-copy">
              <strong>${escapeHtml(step.stepName)}</strong>
              <small>${escapeHtml(step.procedureName)}</small>
            </div>
            <span class="step-rows">${integer.format(step.rowsProcessed || 0)} rows</span>
            <span class="step-duration">${formatDuration(step.durationMs)}</span>
            <span class="step-status">${escapeHtml(step.status)}</span>
          </li>`,
      )
      .join("")
    : '<li class="pipeline-empty">No pipeline steps have been recorded.</li>';

  elements.qualityResults.innerHTML = pipeline.quality.length
    ? pipeline.quality.map((check) => `
      <div class="quality-check ${String(check.status).toLowerCase()}">
        <span class="quality-state">${check.status === "Passed" ? "✓" : "!"}</span>
        <div>
          <strong>${escapeHtml(check.checkName)}</strong>
          <small>${escapeHtml(check.detail)}</small>
        </div>
        <span class="quality-severity">${escapeHtml(check.severity)}</span>
        <span class="quality-count">${integer.format(check.issueCount)} issues</span>
      </div>`).join("")
    : '<div class="pipeline-empty">No quality results are available for this run.</div>';

  const challenges = pipeline.conversionChallenges || [];
  elements.conversionChallengesSection.hidden = challenges.length === 0;
  elements.conversionChallengesSummary.textContent = challenges.length
    ? `${challenges.filter((challenge) => challenge.status === "Passed").length}/${challenges.length} ready`
    : "—";
  elements.conversionChallenges.innerHTML = challenges.map((challenge) => `
    <li class="conversion-challenge ${String(challenge.status).toLowerCase()}">
      <span class="challenge-key">${escapeHtml(challenge.challengeKey)}</span>
      <div>
        <strong>${escapeHtml(challenge.challengeName)}</strong>
        <small>${escapeHtml(challenge.detail)}</small>
      </div>
      <span class="challenge-level">L${escapeHtml(challenge.complexityLevel)}</span>
      <span class="challenge-rows">${integer.format(challenge.sourceRowCount || 0)} rows</span>
      <span class="step-status">${escapeHtml(challenge.status)}</span>
    </li>`).join("");
}

function renderDashboard(data) {
  elements.connectionLabel.textContent = `${data.server.databaseName} online`;
  elements.versionLabel.textContent = `SQL Server ${data.server.productVersion} · ${data.server.productLevel}`;
  elements.serverPill.classList.add("online");
  elements.revenue.textContent = currency.format(data.metrics.revenue);
  elements.orders.textContent = integer.format(data.metrics.orders);
  elements.customers.textContent = integer.format(data.metrics.customers);
  elements.products.textContent = integer.format(data.metrics.products);
  renderPipelineSelector(data.pipelines, data.pipeline.key);
  renderPipeline(data.pipeline);

  const highestSales = Math.max(...data.countries.map((item) => item.sales), 1);
  elements.countryBars.innerHTML = data.countries
    .map(
      (item) => `
        <div class="bar-row">
          <span>${escapeHtml(item.country)}</span>
          <div class="bar-track"><div class="bar-fill" style="--width: ${(item.sales / highestSales) * 100}%"></div></div>
          <span class="bar-value">${currency.format(item.sales)}</span>
        </div>`,
    )
    .join("");

  elements.tableList.innerHTML = data.tables
    .map(
      (table) => `
        <div class="table-item">
          <span class="table-name"><small>${escapeHtml(table.schema)}.</small>${escapeHtml(table.name)}</span>
          <span class="row-count">${integer.format(table.rows)} rows</span>
        </div>`,
    )
    .join("");

  elements.ordersBody.innerHTML = data.orders
    .map(
      (order) => `
        <tr>
          <td class="order-id">#${String(order.orderId).padStart(4, "0")}</td>
          <td>${escapeHtml(order.orderDate)}</td>
          <td>${escapeHtml(order.customer.trim())}</td>
          <td>${escapeHtml(order.product)}</td>
          <td><span class="status ${String(order.status).toLowerCase()}">${escapeHtml(order.status)}</span></td>
          <td class="numeric">${currency.format(order.sales)}</td>
        </tr>`,
    )
    .join("");

  elements.updatedAt.textContent = `Updated ${new Date(data.refreshedAt).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  })}`;
}

async function loadDashboard() {
  elements.refreshButton.disabled = true;
  elements.refreshButton.firstChild.textContent = "Refreshing data ";
  elements.errorBanner.hidden = true;

  try {
    const response = await fetch(`/api/dashboard?pipelineKey=${encodeURIComponent(selectedPipelineKey)}`, {
      headers: { Accept: "application/json" },
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.message || data.error || "Request failed");
    renderDashboard(data);
  } catch (error) {
    elements.connectionLabel.textContent = "Connection unavailable";
    elements.serverPill.classList.remove("online");
    elements.errorBanner.textContent = `Could not load SQL Server data: ${error.message}`;
    elements.errorBanner.hidden = false;
  } finally {
    elements.refreshButton.disabled = false;
    elements.refreshButton.firstChild.textContent = "Refresh data ";
  }
}

async function runPipeline() {
  elements.runPipelineButton.disabled = true;
  elements.runPipelineButton.firstChild.textContent = "Running pipeline ";
  elements.errorBanner.hidden = true;

  try {
    const response = await fetch("/api/pipeline/run", {
      method: "POST",
      headers: { Accept: "application/json", "Content-Type": "application/json" },
      body: JSON.stringify({ pipelineKey: selectedPipelineKey }),
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.message || data.error || "Pipeline request failed");
    await loadDashboard();
  } catch (error) {
    elements.errorBanner.textContent = `Could not run the pipeline: ${error.message}`;
    elements.errorBanner.hidden = false;
  } finally {
    elements.runPipelineButton.disabled = false;
    elements.runPipelineButton.firstChild.textContent = "Run pipeline ";
  }
}

elements.refreshButton.addEventListener("click", loadDashboard);
elements.runPipelineButton.addEventListener("click", runPipeline);
elements.pipelineSelector.addEventListener("change", (event) => {
  selectedPipelineKey = event.target.value;
  loadDashboard();
});
loadDashboard();
