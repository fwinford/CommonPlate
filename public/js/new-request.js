// GENERATED FILE — do not edit.
// Built from src/client/*.ts by build-client.mjs (npm run build:client).
// Edit the TypeScript source; edits here are overwritten by the next build.

// src/client/new-request.ts
var REQUEST_POSTING_PAUSED_MESSAGE = "Posting a meal request is temporarily unavailable.";
async function fetchPublicActionsPaused() {
  try {
    const response = await fetch("/api/public-actions");
    if (!response.ok) return true;
    const body = await response.json();
    return body?.paused !== false;
  } catch {
    return true;
  }
}
function applyRequestFormPause(root) {
  const notice = root.getElementById("pause-notice");
  const submitBtn = root.getElementById("submit-btn");
  if (notice) {
    notice.textContent = REQUEST_POSTING_PAUSED_MESSAGE;
    notice.hidden = false;
  }
  if (submitBtn) {
    submitBtn.disabled = true;
    submitBtn.setAttribute("aria-disabled", "true");
  }
}
function errorMessage(error) {
  return typeof error === "string" ? error : error?.message;
}
function submissionSuccessText(requestId) {
  const submitted = "Request submitted successfully!";
  return requestId ? `${submitted} Request ID: ${requestId}` : submitted;
}
document.addEventListener("DOMContentLoaded", async () => {
  const form = document.getElementById("request-form");
  const submitBtn = document.getElementById("submit-btn");
  const errorMsg = document.getElementById("error-message");
  const successMsg = document.getElementById("success-message");
  const windowTypeRadios = document.querySelectorAll('input[name="windowType"]');
  const timeRangeFields = document.getElementById("time-range-fields");
  if (submitBtn) submitBtn.disabled = true;
  if (await fetchPublicActionsPaused()) {
    applyRequestFormPause(document);
    return;
  }
  if (submitBtn) submitBtn.disabled = false;
  windowTypeRadios.forEach((radio) => {
    radio.addEventListener("change", (e) => {
      const target = e.target;
      if (target.value === "range") {
        timeRangeFields.style.display = "block";
        document.getElementById("windowStart").required = true;
        document.getElementById("windowEnd").required = true;
      } else {
        timeRangeFields.style.display = "none";
        document.getElementById("windowStart").required = false;
        document.getElementById("windowEnd").required = false;
      }
    });
  });
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    errorMsg.style.display = "none";
    successMsg.style.display = "none";
    submitBtn.disabled = true;
    submitBtn.textContent = "Submitting...";
    const formData = new FormData(form);
    const windowType = formData.get("windowType");
    let pickupWindowText = "";
    if (windowType === "asap") {
      pickupWindowText = "ASAP";
    } else {
      const start = formData.get("windowStart");
      const end = formData.get("windowEnd");
      if (start && end) {
        try {
          const s = new Date(start);
          const e2 = new Date(end);
          const sameDay = s.toDateString() === e2.toDateString();
          const optsDate = { month: "short", day: "numeric" };
          const optsTime = { hour: "numeric", minute: "2-digit" };
          if (sameDay) {
            pickupWindowText = `${s.toLocaleDateString(void 0, optsDate)}, ${s.toLocaleTimeString(void 0, optsTime)} \u2013 ${e2.toLocaleTimeString(void 0, optsTime)}`;
          } else {
            pickupWindowText = `${s.toLocaleString()} \u2013 ${e2.toLocaleString()}`;
          }
        } catch {
          pickupWindowText = "Requested time range";
        }
      }
    }
    const data = {
      vendor: formData.get("vendor"),
      food: formData.get("food"),
      pickupName: formData.get("pickupName"),
      email: formData.get("email"),
      pickupWindowText
    };
    if (windowType === "range") {
      const start = formData.get("windowStart");
      const end = formData.get("windowEnd");
      if (start) {
        const startDate = new Date(start);
        data.windowStart = startDate.toISOString();
      }
      if (end) {
        const endDate = new Date(end);
        data.windowEnd = endDate.toISOString();
      }
    }
    try {
      const response = await fetch("/api/request", {
        method: "POST",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify(data)
      });
      const result = await response.json();
      if (!response.ok) {
        throw new Error(errorMessage(result.error) || "Failed to submit request");
      }
      successMsg.textContent = submissionSuccessText(result.request?.id);
      successMsg.style.display = "block";
      form.reset();
      setTimeout(() => {
        window.location.href = "/";
      }, 3e3);
    } catch (error) {
      const errorMessage2 = error instanceof Error ? error.message : "Unknown error";
      errorMsg.textContent = `Error: ${errorMessage2}`;
      errorMsg.style.display = "block";
    } finally {
      submitBtn.disabled = false;
      submitBtn.textContent = "Submit Request";
    }
  });
});
export {
  REQUEST_POSTING_PAUSED_MESSAGE,
  applyRequestFormPause,
  errorMessage,
  fetchPublicActionsPaused,
  submissionSuccessText
};
//# sourceMappingURL=new-request.js.map
