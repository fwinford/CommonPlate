// src/client/new-request.ts
// Form submission handling for new meal requests

interface RequestFormData {
  vendor: string;
  food: string;
  pickupName: string;
  email: string;
  pickupWindowText: string;
  windowStart?: string;
  windowEnd?: string;
}

interface RequestResponse {
  id: string;
  error?: string;
}

document.addEventListener('DOMContentLoaded', () => {
  const form = document.getElementById('request-form') as HTMLFormElement;
  const submitBtn = document.getElementById('submit-btn') as HTMLButtonElement;
  const errorMsg = document.getElementById('error-message') as HTMLDivElement;
  const successMsg = document.getElementById('success-message') as HTMLDivElement;
  const windowTypeRadios = document.querySelectorAll('input[name="windowType"]') as NodeListOf<HTMLInputElement>;
  const timeRangeFields = document.getElementById('time-range-fields') as HTMLDivElement;

  // Show/hide time range fields based on selection
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
    
    // Clear previous messages
    errorMsg.style.display = 'none';
    successMsg.style.display = 'none';
    submitBtn.disabled = true;
    submitBtn.textContent = 'Submitting...';

    // Gather form data
    const formData = new FormData(form);
    const windowType = formData.get('windowType') as string;

    // Compute pickupWindowText based on selection
    let pickupWindowText = '';
    
    if (windowType === 'asap') {
      pickupWindowText = 'ASAP (within the next hour)';
    } else {
      // Format the time range
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

    // include structured window times when provided
    if (windowType === 'range') {
      const start = formData.get('windowStart') as string;
      const end = formData.get('windowEnd') as string;
      // Convert local datetime (from datetime-local input) to UTC ISO string
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
        throw new Error(result.error || 'Failed to submit request');
      }

      // Success!
      successMsg.textContent = `Request submitted successfully! Check your email for confirmation. Request ID: ${result.id}`;
      successMsg.style.display = 'block';
      form.reset();

      // Redirect to home after 3 seconds
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
