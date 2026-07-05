// src/utils/date.ts
function formatMealRequestWindow(start, end, fallback) {
  if (fallback && /\b(AM|PM)\b|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec/i.test(fallback)) {
    return fallback;
  }
  if (!start && !end) return fallback || "Time window not specified";
  try {
    const s = start ? new Date(start) : null;
    const e = end ? new Date(end) : null;
    const optsDate = { month: "short", day: "numeric" };
    const optsTime = { hour: "numeric", minute: "2-digit", hour12: true, timeZone: "America/New_York" };
    if (s && e) {
      const sameDay = s.toLocaleDateString("en-US", { timeZone: "America/New_York" }) === e.toLocaleDateString("en-US", { timeZone: "America/New_York" });
      if (sameDay) {
        return `${s.toLocaleDateString("en-US", optsDate)}, ${s.toLocaleTimeString("en-US", optsTime)} \u2013 ${e.toLocaleTimeString("en-US", optsTime)}`;
      }
      return `${s.toLocaleString("en-US", { ...optsDate, ...optsTime })} \u2013 ${e.toLocaleString("en-US", { ...optsDate, ...optsTime })}`;
    }
    if (s) return `${s.toLocaleDateString("en-US", optsDate)}, ${s.toLocaleTimeString("en-US", optsTime)}`;
    if (e) return `Until ${e.toLocaleString("en-US", { ...optsDate, ...optsTime })}`;
    return fallback || "Time window not specified";
  } catch {
    if (start) return new Date(start).toLocaleString("en-US", { timeZone: "America/New_York" });
    if (end) return new Date(end).toLocaleString("en-US", { timeZone: "America/New_York" });
    return fallback || "Time window not specified";
  }
}

// src/client/home.ts
function clientEscapeHtml(text) {
  const div = document.createElement("div");
  div.textContent = text;
  return div.innerHTML;
}
function clientShowRequestDetail(request) {
  const modal = document.createElement("div");
  modal.className = "modal-overlay";
  const windowText = request.isAsap ? "ASAP (within the next hour)" : formatMealRequestWindow(request.windowStart, request.windowEnd, request.pickupWindowText || "Not specified");
  modal.innerHTML = `
    <div class="modal-content">
      <button class="modal-close" aria-label="Close">&times;</button>
      <div class="modal-header">
        <h2>Request Details</h2>
      </div>
      <div class="modal-body">
        <div class="detail-group">
          <label>Pickup Window</label>
          <p class="detail-window">${clientEscapeHtml(windowText)}</p>
        </div>
        <div class="detail-group">
          <label>Pickup Name</label>
          <p>${clientEscapeHtml(request.pickupName)}</p>
        </div>
        <div class="detail-group">
          <label>What They Want</label>
          <p class="detail-food">${clientEscapeHtml(request.food)}</p>
        </div>
        <div class="detail-group">
          <label>Where From</label>
          <p>${clientEscapeHtml(request.vendor)}</p>
        </div>
      </div>
      <div class="modal-actions">
        <button class="btn btn-primary modal-order-btn">I'll Order This</button>
        <button class="btn btn-secondary modal-cancel-btn">Maybe Later</button>
      </div>
    </div>
  `;
  document.body.appendChild(modal);
  const closeModal = () => {
    modal.remove();
  };
  modal.querySelector(".modal-close")?.addEventListener("click", closeModal);
  modal.querySelector(".modal-cancel-btn")?.addEventListener("click", closeModal);
  modal.addEventListener("click", (e) => {
    if (e.target === modal) closeModal();
  });
  modal.querySelector(".modal-order-btn")?.addEventListener("click", () => {
    window.location.href = `/request/${request._id}/fulfill`;
    closeModal();
  });
  setTimeout(() => {
    modal.querySelector(".modal-close")?.focus();
  }, 100);
}
document.addEventListener("DOMContentLoaded", async () => {
  const subscribeBtn = document.getElementById("subscribe-cta-btn");
  const subscribePanel = document.getElementById("subscribe-panel");
  const subscribeForm = document.getElementById("subscribe-form");
  const subscribeEmail = document.getElementById("subscribe-email");
  const subscribeCancel = document.getElementById("subscribe-cancel");
  const subscribeMessage = document.getElementById("subscribe-message");
  if (subscribeBtn && subscribePanel && subscribeForm && subscribeEmail && subscribeCancel && subscribeMessage) {
    subscribeBtn.addEventListener("click", () => {
      subscribePanel.style.display = "block";
      subscribeEmail.focus();
      subscribeMessage.textContent = "";
    });
    subscribeCancel.addEventListener("click", () => {
      subscribePanel.style.display = "none";
      subscribeForm.reset();
      subscribeMessage.textContent = "";
    });
    subscribeForm.addEventListener("submit", async (e) => {
      e.preventDefault();
      subscribeMessage.textContent = "";
      const email = subscribeEmail.value.trim();
      if (!email) {
        subscribeMessage.textContent = "Please enter your NYU email.";
        return;
      }
      subscribeForm.querySelector(".subscribe-submit")?.setAttribute("disabled", "true");
      subscribeMessage.textContent = "Subscribing...";
      try {
        const res = await fetch("/api/subscribe", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ email })
        });
        const data = await res.json();
        if (res.ok) {
          subscribeMessage.textContent = "Check your email to confirm your subscription!";
          subscribeForm.reset();
          setTimeout(() => {
            subscribePanel.style.display = "none";
            subscribeMessage.textContent = "";
          }, 3e3);
        } else {
          subscribeMessage.textContent = data?.error || "Could not subscribe. Please try again.";
        }
      } catch (err) {
        subscribeMessage.textContent = "Network error. Please try again.";
      } finally {
        subscribeForm.querySelector(".subscribe-submit")?.removeAttribute("disabled");
      }
    });
  }
  const requestsList = document.getElementById("requests-list");
  const activeCountEl = document.getElementById("active-count");
  const totalSharedEl = document.getElementById("total-shared");
  const heroCountEl = document.getElementById("active-subscriber-hero");
  async function updateActiveSubscriberCount() {
    try {
      const resp = await fetch("/api/active-subscriber-count");
      if (resp.ok) {
        const data = await resp.json();
        const msg = typeof data.count === "number" && data.count > 0 ? `${data.count} volunteer${data.count === 1 ? "" : "s"} ready to fulfill requests` : "Volunteers are signing up\u2014check back soon!";
        if (activeCountEl) activeCountEl.textContent = msg;
        if (heroCountEl) heroCountEl.textContent = msg;
      } else {
        if (activeCountEl) activeCountEl.textContent = "";
        if (heroCountEl) heroCountEl.textContent = "";
      }
    } catch {
      if (activeCountEl) activeCountEl.textContent = "";
      if (heroCountEl) heroCountEl.textContent = "";
    }
  }
  updateActiveSubscriberCount();
  try {
    const statsResponse = await fetch("/api/stats");
    if (statsResponse.ok) {
      const stats = await statsResponse.json();
      if (totalSharedEl) {
        totalSharedEl.textContent = `${stats.totalShared} total meals shared`;
      }
    }
    const requestsResponse = await fetch("/api/requests");
    if (requestsResponse.ok) {
      const requests = await requestsResponse.json();
      if (activeCountEl) {
        const activeCount = requests.length;
        activeCountEl.textContent = activeCount === 1 ? "1 active request right now" : `${activeCount} active requests right now`;
      }
      if (!requestsList) return;
      if (requests.length === 0) {
        requestsList.innerHTML = '<p class="loading">No active requests right now.</p>';
      } else {
        const formatWindow = (start, end, fallback) => {
          return formatMealRequestWindow(start, end, fallback);
        };
        requestsList.innerHTML = requests.map((req) => {
          let windowText = "Time window not specified";
          if (req.isAsap) {
            windowText = "ASAP (within the next hour)";
          } else if (req.windowStart || req.windowEnd) {
            windowText = formatWindow(req.windowStart, req.windowEnd, req.pickupWindowText);
          } else {
            windowText = req.pickupWindowText || "Time window not specified";
          }
          return `
          <div class="request-card" data-request-id="${clientEscapeHtml(req._id)}">
            <div class="card-window">${clientEscapeHtml(windowText)}</div>
            <div class="card-pickup">Pickup: ${clientEscapeHtml(req.pickupName)}</div>
            <button class="card-action-btn" data-id="${clientEscapeHtml(req._id)}">Order This</button>
          </div>
        `;
        }).join("");
        document.querySelectorAll(".card-action-btn").forEach((btn) => {
          btn.addEventListener("click", (e) => {
            e.stopPropagation();
            const requestId = btn.dataset.id;
            window.location.href = `/request/${requestId}/fulfill`;
          });
        });
        document.querySelectorAll(".request-card").forEach((card) => {
          card.addEventListener("click", (e) => {
            if (e.target.classList.contains("card-action-btn")) return;
            const requestId = card.dataset.requestId;
            const request = requests.find((r) => r._id === requestId);
            if (request) {
              clientShowRequestDetail(request);
            }
          });
        });
      }
    } else if (requestsList) {
      requestsList.innerHTML = '<p class="loading">Unable to load requests.</p>';
    }
  } catch (error) {
    console.error("Error fetching requests:", error);
    if (requestsList) requestsList.innerHTML = '<p class="loading">Error loading requests.</p>';
  }
});
//# sourceMappingURL=home.js.map
