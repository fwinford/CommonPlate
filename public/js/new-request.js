// src/client/new-request.ts
document.addEventListener("DOMContentLoaded", () => {
  const form = document.getElementById("request-form");
  const submitBtn = document.getElementById("submit-btn");
  const errorMsg = document.getElementById("error-message");
  const successMsg = document.getElementById("success-message");
  const windowTypeRadios = document.querySelectorAll('input[name="windowType"]');
  const timeRangeFields = document.getElementById("time-range-fields");
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
      pickupWindowText = "ASAP (within the next hour)";
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
        throw new Error(result.error || "Failed to submit request");
      }
      successMsg.textContent = `Request submitted successfully! Check your email for confirmation. Request ID: ${result.id}`;
      successMsg.style.display = "block";
      form.reset();
      setTimeout(() => {
        window.location.href = "/";
      }, 3e3);
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : "Unknown error";
      errorMsg.textContent = `Error: ${errorMessage}`;
      errorMsg.style.display = "block";
    } finally {
      submitBtn.disabled = false;
      submitBtn.textContent = "Submit Request";
    }
  });
});
//# sourceMappingURL=new-request.js.map
