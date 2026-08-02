// src/client/new-request.ts
// Form submission handling for new meal requests

export const REQUEST_POSTING_PAUSED_MESSAGE =
  "Posting a meal request is temporarily unavailable.";

/**
 * Asks the server whether public actions are paused. Any failure is treated as
 * paused: showing the notice when posting actually works is harmless, while
 * hiding it when posting is refused would let a student fill the whole form
 * for nothing.
 */
export async function fetchPublicActionsPaused(): Promise<boolean> {
  try {
    const response = await fetch('/api/public-actions');
    if (!response.ok) return true;
    const body = await response.json();
    return body?.paused !== false;
  } catch {
    return true;
  }
}

/**
 * Presents the pause before any data entry and removes the submit action.
 * The server refuses the POST regardless; this exists so nobody discovers the
 * pause only after filling the form.
 */
export function applyRequestFormPause(root: Document): void {
  const notice = root.getElementById('pause-notice');
  const submitBtn = root.getElementById('submit-btn') as HTMLButtonElement | null;

  if (notice) {
    notice.textContent = REQUEST_POSTING_PAUSED_MESSAGE;
    notice.hidden = false;
  }
  if (submitBtn) {
    submitBtn.disabled = true;
    submitBtn.setAttribute('aria-disabled', 'true');
  }
}

interface RequestFormData {
  vendor: string;
  food: string;
  pickupName: string;
  email: string;
  pickupWindowText: string;
  windowStart?: string;
  windowEnd?: string;
}

/// Decodes both the structured create-error envelope and a flat error string.
interface RequestResponse {
  request?: { id: string };
  error?: string | { code: string; message: string };
}

export function errorMessage(error: RequestResponse['error']): string | undefined {
  return typeof error === 'string' ? error : error?.message;
}

/// States only what the `201` proves: the request was validated and persisted.
/// It deliberately does not mention email. Requester confirmation is now sent
/// after persistence and cannot undo it (`src/createRequestRoute.ts`), so a
/// send that fails still returns `201` — promising a message here would tell
/// the student to wait for something that may never arrive.
export function submissionSuccessText(requestId?: string): string {
  const submitted = 'Request submitted successfully!';
  return requestId ? `${submitted} Request ID: ${requestId}` : submitted;
}

document.addEventListener('DOMContentLoaded', async () => {
  const form = document.getElementById('request-form') as HTMLFormElement;
  const submitBtn = document.getElementById('submit-btn') as HTMLButtonElement;
  const errorMsg = document.getElementById('error-message') as HTMLDivElement;
  const successMsg = document.getElementById('success-message') as HTMLDivElement;
  const windowTypeRadios = document.querySelectorAll('input[name="windowType"]') as NodeListOf<HTMLInputElement>;
  const timeRangeFields = document.getElementById('time-range-fields') as HTMLDivElement;

  // Held disabled until the pause state is known, so the form is never
  // submittable during the probe.
  if (submitBtn) submitBtn.disabled = true;

  if (await fetchPublicActionsPaused()) {
    applyRequestFormPause(document);
    return;
  }

  if (submitBtn) submitBtn.disabled = false;

  windowTypeRadios.forEach(radio => {
    radio.addEventListener('change', (e) => {
      const target = e.target as HTMLInputElement;
      if (target.value === 'range') {
        timeRangeFields.style.display = 'block';
        (document.getElementById('windowStart') as HTMLInputElement).required = true;
        (document.getElementById('windowEnd') as HTMLInputElement).required = true;
      } else {
        timeRangeFields.style.display = 'none';
        (document.getElementById('windowStart') as HTMLInputElement).required = false;
        (document.getElementById('windowEnd') as HTMLInputElement).required = false;
      }
    });
  });

  form.addEventListener('submit', async (e: Event) => {
    e.preventDefault();
    
    errorMsg.style.display = 'none';
    successMsg.style.display = 'none';
    submitBtn.disabled = true;
    submitBtn.textContent = 'Submitting...';

    const formData = new FormData(form);
    const windowType = formData.get('windowType') as string;

    let pickupWindowText = '';
    
    if (windowType === 'asap') {
      pickupWindowText = 'ASAP (within the next 5 hours)';
    } else {
      const start = formData.get('windowStart') as string;
      const end = formData.get('windowEnd') as string;
      
      if (start && end) {
        try {
          const s = new Date(start);
          const e = new Date(end);
          const sameDay = s.toDateString() === e.toDateString();
          const optsDate: Intl.DateTimeFormatOptions = { month: 'short', day: 'numeric' };
          const optsTime: Intl.DateTimeFormatOptions = { hour: 'numeric', minute: '2-digit' };
          
          if (sameDay) {
            pickupWindowText = `${s.toLocaleDateString(undefined, optsDate)}, ${s.toLocaleTimeString(undefined, optsTime)} – ${e.toLocaleTimeString(undefined, optsTime)}`;
          } else {
            pickupWindowText = `${s.toLocaleString()} – ${e.toLocaleString()}`;
          }
        } catch {
          pickupWindowText = 'Requested time range';
        }
      }
    }

    const data: RequestFormData = {
      vendor: formData.get('vendor') as string,
      food: formData.get('food') as string,
      pickupName: formData.get('pickupName') as string,
      email: formData.get('email') as string,
      pickupWindowText,
    };

    if (windowType === 'range') {
      const start = formData.get('windowStart') as string;
      const end = formData.get('windowEnd') as string;
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
      const response = await fetch('/api/request', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(data),
      });

      const result: RequestResponse = await response.json();

      if (!response.ok) {
        throw new Error(errorMessage(result.error) || 'Failed to submit request');
      }

      successMsg.textContent = submissionSuccessText(result.request?.id);
      successMsg.style.display = 'block';
      form.reset();

      setTimeout(() => {
        window.location.href = '/';
      }, 3000);

    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error';
      errorMsg.textContent = `Error: ${errorMessage}`;
      errorMsg.style.display = 'block';
    } finally {
      submitBtn.disabled = false;
      submitBtn.textContent = 'Submit Request';
    }
  });
});
