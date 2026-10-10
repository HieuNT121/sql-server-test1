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
  pipelineStatus: document.querySelector("#pipeline-status"),
  pipelineLastRun: document.querySelector("#pipeline-last-run"),
  pipelineTrigger: document.querySelector("#pipeline-trigger"),
  pipelineRows: document.querySelector("#pipeline-rows"),
  pipelineDuration: document.querySelector("#pipeline-duration"),
  pipelineSteps: document.querySelector("#pipeline-steps"),
  pipelineError: document.querySelector("#pipeline-error"),
  runPipelineButton: document.querySelector("#run-pipeline-button"),
  errorBanner: document.querySelector("#error-banner"),
};

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

function renderPipeline(pipeline) {
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
}

function renderDashboard(data) {
  elements.connectionLabel.textContent = `${data.server.databaseName} online`;
  elements.versionLabel.textContent = `SQL Server ${data.server.productVersion} · ${data.server.productLevel}`;
  elements.serverPill.classList.add("online");
  elements.revenue.textContent = currency.format(data.metrics.revenue);
  elements.orders.textContent = integer.format(data.metrics.orders);
  elements.customers.textContent = integer.format(data.metrics.customers);
  elements.products.textContent = integer.format(data.metrics.products);
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
    const response = await fetch("/api/dashboard", { headers: { Accept: "application/json" } });
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
    const response = await fetch("/api/pipeline/run", { method: "POST", headers: { Accept: "application/json" } });
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
loadDashboard();
