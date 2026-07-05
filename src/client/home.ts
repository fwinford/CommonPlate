// src/client/home.ts
// Fetch and display meal requests on the homepage
import { formatMealRequestWindow } from "../utils/date.js";

interface MealRequest {
  _id: string;
  vendor: string;
  food: string;
  pickupName: string;
  pickupWindowText: string;
  windowStart?: string;
  windowEnd?: string;
  isAsap?: boolean;
  status: string;
}


// Utility function to escape HTML and prevent XSS
function clientEscapeHtml(text: string): string {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

// Show request detail modal
function clientShowRequestDetail(request: MealRequest): void {
  const modal = document.createElement('div');
  modal.className = 'modal-overlay';
  const windowText = request.isAsap
    ? 'ASAP (within the next hour)'
    : formatMealRequestWindow(request.windowStart, request.windowEnd, request.pickupWindowText || 'Not specified');
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
  modal.querySelector('.modal-close')?.addEventListener('click', closeModal);
  modal.querySelector('.modal-cancel-btn')?.addEventListener('click', closeModal);
  modal.addEventListener('click', (e) => {
    if (e.target === modal) closeModal();
  });
  modal.querySelector('.modal-order-btn')?.addEventListener('click', () => {
    window.location.href = `/request/${request._id}/fulfill`;
    closeModal();
  });
  setTimeout(() => {
    (modal.querySelector('.modal-close') as HTMLElement)?.focus();
  }, 100);
}

document.addEventListener('DOMContentLoaded', async () => {
  // --- SUBSCRIBE PANEL LOGIC ---
  const subscribeBtn = document.getElementById('subscribe-cta-btn');
  const subscribePanel = document.getElementById('subscribe-panel');
  const subscribeForm = document.getElementById('subscribe-form') as HTMLFormElement | null;
  const subscribeEmail = document.getElementById('subscribe-email') as HTMLInputElement | null;
  const subscribeCancel = document.getElementById('subscribe-cancel');
  const subscribeMessage = document.getElementById('subscribe-message');

  if (subscribeBtn && subscribePanel && subscribeForm && subscribeEmail && subscribeCancel && subscribeMessage) {
    subscribeBtn.addEventListener('click', () => {
      subscribePanel.style.display = 'block';
      subscribeEmail.focus();
      subscribeMessage.textContent = '';
    });
    subscribeCancel.addEventListener('click', () => {
      subscribePanel.style.display = 'none';
      subscribeForm.reset();
      subscribeMessage.textContent = '';
    });
    subscribeForm.addEventListener('submit', async (e) => {
      e.preventDefault();
      subscribeMessage.textContent = '';
      const email = subscribeEmail.value.trim();
      if (!email) {
        subscribeMessage.textContent = 'Please enter your NYU email.';
        return;
      }
      subscribeForm.querySelector('.subscribe-submit')?.setAttribute('disabled', 'true');
      subscribeMessage.textContent = 'Subscribing...';
      try {
        const res = await fetch('/api/subscribe', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ email })
        });
        const data = await res.json();
        if (res.ok) {
          subscribeMessage.textContent = 'Check your email to confirm your subscription!';
          subscribeForm.reset();
          setTimeout(() => {
            subscribePanel.style.display = 'none';
            subscribeMessage.textContent = '';
          }, 3000);
        } else {
          subscribeMessage.textContent = data?.error || 'Could not subscribe. Please try again.';
        }
      } catch (err) {
        subscribeMessage.textContent = 'Network error. Please try again.';
      } finally {
        subscribeForm.querySelector('.subscribe-submit')?.removeAttribute('disabled');
      }
    });
  }

  const requestsList = document.getElementById('requests-list');
  const activeCountEl = document.getElementById('active-count');
  const totalSharedEl = document.getElementById('total-shared');

  // Fetch and display active subscriber count in both hero and stats
  const heroCountEl = document.getElementById('active-subscriber-hero');
  async function updateActiveSubscriberCount() {
    try {
      const resp = await fetch('/api/active-subscriber-count');
      if (resp.ok) {
        const data = await resp.json();
        const msg = (typeof data.count === 'number' && data.count > 0)
          ? `${data.count} volunteer${data.count === 1 ? '' : 's'} ready to fulfill requests`
          : 'Volunteers are signing up—check back soon!';
        if (activeCountEl) activeCountEl.textContent = msg;
        if (heroCountEl) heroCountEl.textContent = msg;
      } else {
        if (activeCountEl) activeCountEl.textContent = '';
        if (heroCountEl) heroCountEl.textContent = '';
      }
    } catch {
      if (activeCountEl) activeCountEl.textContent = '';
      if (heroCountEl) heroCountEl.textContent = '';
    }
  }
  updateActiveSubscriberCount();


  try {
    // Fetch stats
    const statsResponse = await fetch('/api/stats');
    if (statsResponse.ok) {
      const stats = await statsResponse.json();
      if (totalSharedEl) {
        totalSharedEl.textContent = `${stats.totalShared} total meals shared`;
      }
    }
    
    // Fetch requests
    const requestsResponse = await fetch('/api/requests');
    if (requestsResponse.ok) {
      const requests: MealRequest[] = await requestsResponse.json();
      
      // Update activity stats
      if (activeCountEl) {
        const activeCount = requests.length;
        activeCountEl.textContent = activeCount === 1 
          ? '1 active request right now' 
          : `${activeCount} active requests right now`;
      }
      
      if (!requestsList) return;
      if (requests.length === 0) {
        requestsList.innerHTML = '<p class="loading">No active requests right now.</p>';
      } else {
        // Helper to format window start/end concisely
        const formatWindow = (start?: string, end?: string, fallback?: string) => {
          return formatMealRequestWindow(start, end, fallback);
        };

  requestsList.innerHTML = requests.map(req => {
          let windowText = 'Time window not specified';
          if (req.isAsap) {
            windowText = 'ASAP (within the next hour)';
          } else if (req.windowStart || req.windowEnd) {
            windowText = formatWindow(req.windowStart, req.windowEnd, req.pickupWindowText);
          } else {
            windowText = req.pickupWindowText || 'Time window not specified';
          }

          return `
          <div class="request-card" data-request-id="${clientEscapeHtml(req._id)}">
            <div class="card-window">${clientEscapeHtml(windowText)}</div>
            <div class="card-pickup">Pickup: ${clientEscapeHtml(req.pickupName)}</div>
            <button class="card-action-btn" data-id="${clientEscapeHtml(req._id)}">Order This</button>
          </div>
        `}).join('');
        
        // Make the button go directly to the fulfill page
        document.querySelectorAll('.card-action-btn').forEach(btn => {
          btn.addEventListener('click', (e) => {
            e.stopPropagation(); // Prevent card click
            const requestId = (btn as HTMLElement).dataset.id;
            // Go directly to fulfill page
            window.location.href = `/request/${requestId}/fulfill`;
          });
        });
        
        // Add click handlers for request cards (view details)
        document.querySelectorAll('.request-card').forEach(card => {
          card.addEventListener('click', (e) => {
            // Don't show details if clicking the button
            if ((e.target as HTMLElement).classList.contains('card-action-btn')) return;
            
            const requestId = (card as HTMLElement).dataset.requestId;
            const request = requests.find(r => r._id === requestId);
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
    console.error('Error fetching requests:', error);
    if (requestsList) requestsList.innerHTML = '<p class="loading">Error loading requests.</p>';
  }
});
