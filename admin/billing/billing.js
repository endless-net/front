(async function () {
  const root = document.querySelector('[data-billing-root]');
  if (!root) return;
  const apiBase = (window.ENDLESSNET_API_BASE || localStorage.getItem('endlessnet_api_base') || '').replace(/\/$/, '');
  const token = localStorage.getItem('endlessnet_token') || new URLSearchParams(location.hash.replace(/^#/, '')).get('token') || '';
  const path = location.pathname;
  const headers = token ? { Authorization: 'Bearer ' + token } : {};
  async function request(method, url, body) {
    const res = await fetch(apiBase + url, {
      method,
      headers: body ? { ...headers, 'Content-Type': 'application/json' } : headers,
      body: body ? JSON.stringify(body) : undefined
    });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  }
  function section(title, body) {
    return `<section class="billing-panel"><h2>${title}</h2>${body}</section>`;
  }
  function money(value, currency) {
    return value < 0 ? 'по запросу' : `${(value / 100).toFixed(2)} ${currency}`;
  }
  try {
    const plansPayload = await request('GET', '/api/v1/billing/plans');
    const accountsPayload = token ? await request('GET', '/api/v1/accounts') : { accounts: [] };
    const account = accountsPayload.accounts && accountsPayload.accounts[0];
    let html = `<nav class="billing-nav"><a href="/admin/billing/">Overview</a><a href="/admin/billing/plans/">Plans</a><a href="/admin/billing/invoices/">Invoices</a><a href="/admin/billing/usage/">Usage</a><a href="/admin/billing/license/">License</a><a href="/admin/billing/enterprise/">Enterprise</a></nav>`;
    if (!token) {
      html += section('Sign in required', '<p>Open the admin console login first.</p>');
      root.innerHTML = html;
      return;
    }
    if (!account) {
      html += section('No account', '<p>Create an account through the API or login flow.</p>');
      root.innerHTML = html;
      return;
    }
    if (path.includes('/plans')) {
      html += '<div class="billing-grid">' + plansPayload.plans.filter(p => p.public).map(p => section(p.name, `<p>${p.description}</p><p>${money(p.monthly_price, p.currency)}</p><button data-plan="${p.id}">Checkout</button>`)).join('') + '</div>';
    } else if (path.includes('/checkout')) {
      html += section('Checkout', '<p>Select a plan from Billing plans. Redirects are created only by the backend checkout endpoint.</p>');
    } else if (path.includes('/yookassa/return')) {
      const checkoutID = new URLSearchParams(location.search).get('checkout_id') || localStorage.getItem('endlessnet_checkout_id') || '';
      html += section('Payment check', `<p id="checkout-status">Checking ${checkoutID || 'checkout'}...</p>`);
      root.innerHTML = html;
      if (checkoutID) {
        const status = await request('GET', `/api/v1/accounts/${account.id}/billing/checkout/${checkoutID}`);
        document.getElementById('checkout-status').textContent = `${status.id}: ${status.status}`;
      }
      return;
    } else if (path.includes('/success')) {
      html += section('Payment succeeded', '<p>The subscription is active after backend verification.</p>');
    } else if (path.includes('/failure')) {
      html += section('Payment failed', '<p>The checkout did not grant paid entitlements.</p>');
    } else if (path.includes('/invoices')) {
      const invoices = await request('GET', `/api/v1/accounts/${account.id}/billing/invoices`);
      html += section('Invoices', `<pre>${JSON.stringify(invoices.invoices, null, 2)}</pre>`);
    } else if (path.includes('/usage')) {
      const usage = await request('GET', `/api/v1/accounts/${account.id}/billing/usage`);
      html += section('Usage', `<pre>${JSON.stringify(usage, null, 2)}</pre>`);
    } else if (path.includes('/legal')) {
      const legal = await request('GET', `/api/v1/accounts/${account.id}/billing/legal`);
      html += section('Legal profile', `<pre>${JSON.stringify(legal, null, 2)}</pre>`);
    } else if (path.includes('/license')) {
      const license = await request('GET', `/api/v1/accounts/${account.id}/license`);
      html += section('Offline license', `<pre>${JSON.stringify(license, null, 2)}</pre>`);
    } else if (path.includes('/enterprise')) {
      html += section('Enterprise', '<p>Enterprise and MSP plans use manual invoice and offline license flows.</p><p><a href="/contact-sales/">Contact sales</a></p>');
    } else {
      const subscription = await request('GET', `/api/v1/accounts/${account.id}/billing/subscription`);
      const usage = await request('GET', `/api/v1/accounts/${account.id}/billing/usage`);
      html += section('Billing overview', `<pre>${JSON.stringify({ account, subscription, usage }, null, 2)}</pre>`);
    }
    root.innerHTML = html;
    root.querySelectorAll('button[data-plan]').forEach(button => {
      button.addEventListener('click', async () => {
        const checkout = await request('POST', `/api/v1/accounts/${account.id}/billing/checkout`, { plan_id: button.dataset.plan, billing_period: 'monthly' });
        localStorage.setItem('endlessnet_checkout_id', checkout.id);
        if (checkout.confirmation_url) location.href = checkout.confirmation_url;
        else location.href = '/admin/billing/invoices/';
      });
    });
  } catch (err) {
    root.innerHTML = section('Billing error', `<pre>${String(err.message || err)}</pre>`);
  }
})();
