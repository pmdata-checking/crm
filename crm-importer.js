(function() {
  var SUPABASE_URL = 'https://zmnofnsvonarpevzrkuo.supabase.co';
  var SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inptbm9mbnN2b25hcnBldnpya3VvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM0MTE5NzYsImV4cCI6MjA4ODk4Nzk3Nn0.1xvTgXFBDiyEFUtziIaZ0s7mByEu3wZsg29eStU13ao';

  if (!window.location.href.includes('windowbase.info/prospect/customer')) {
    alert('Please navigate to the Customers list page on windowbase.info first.');
    return;
  }

  if (document.getElementById('crm-importer-overlay')) {
    document.getElementById('crm-importer-overlay').remove();
    return;
  }

  var style = document.createElement('style');
  style.textContent = '\
    #crm-importer-overlay{position:fixed;top:0;right:0;width:380px;height:100vh;background:#1e3a5f;color:#fff;z-index:99999;display:flex;flex-direction:column;box-shadow:-4px 0 20px rgba(0,0,0,0.4);font-family:Arial,sans-serif;}\
    #crm-importer-overlay h3{margin:0;padding:16px;background:#5a8a1f;font-size:16px;}\
    #crm-panel-body{flex:1;overflow-y:auto;padding:12px;}\
    #crm-importer-overlay .crm-btn{background:#5a8a1f;color:#fff;border:none;padding:10px 16px;border-radius:5px;cursor:pointer;font-size:14px;width:100%;margin-top:8px;}\
    #crm-importer-overlay .crm-btn:hover{background:#4a7a0f;}\
    #crm-importer-overlay .crm-btn.cancel{background:#c0392b;}\
    #crm-importer-overlay .crm-btn.cancel:hover{background:#a93226;}\
    #crm-importer-overlay .crm-customer-item{background:rgba(255,255,255,0.1);border-radius:5px;padding:8px 10px;margin:5px 0;display:flex;align-items:center;gap:8px;cursor:pointer;}\
    #crm-importer-overlay .crm-customer-item:hover{background:rgba(255,255,255,0.2);}\
    #crm-importer-overlay .crm-customer-item input{width:16px;height:16px;cursor:pointer;flex-shrink:0;}\
    #crm-importer-overlay .crm-customer-item label{cursor:pointer;font-size:13px;line-height:1.3;}\
    #crm-status{padding:12px;background:rgba(0,0,0,0.2);font-size:12px;min-height:40px;}\
    #crm-progress{height:4px;background:#5a8a1f;width:0%;transition:width 0.3s;}\
    .crm-select-all-row{display:flex;align-items:center;gap:8px;padding:8px 0;border-bottom:1px solid rgba(255,255,255,0.2);margin-bottom:8px;}\
    .crm-select-all-row label{font-size:13px;cursor:pointer;}\
    .crm-count{font-size:12px;color:rgba(255,255,255,0.7);margin-bottom:8px;}\
  ';
  document.head.appendChild(style);

  var overlay = document.createElement('div');
  overlay.id = 'crm-importer-overlay';
  overlay.innerHTML = '<h3>\uD83C\uDFE2 Import to CRM</h3>'
    + '<div id="crm-progress"></div>'
    + '<div id="crm-panel-body">'
    + '<div id="crm-status">Scanning current page for OK customers...</div>'
    + '<div id="crm-customer-list"></div>'
    + '</div>';
  document.body.appendChild(overlay);

  function setStatus(msg) { document.getElementById('crm-status').textContent = msg; }
  function setProgress(pct) { document.getElementById('crm-progress').style.width = pct + '%'; }

  function parseCustomersFromPage(doc) {
    var rows = doc.querySelectorAll('table tr');
    var customers = [];
    rows.forEach(function(row) {
      var cells = row.querySelectorAll('td');
      if (cells.length < 4) return;
      var statusCell = cells[cells.length - 1];
      var status = statusCell.textContent.trim();
      if (status !== 'OK') return;
      var link = row.querySelector('a');
      if (!link) return;
      var href = link.href || '';
      var pkMatch = href.match(/pk=(\d+)/);
      if (!pkMatch) return;
      var pk = pkMatch[1];
      var company = cells[0].textContent.trim();
      var contact = cells[1].textContent.trim();
      var postcode = cells[cells.length - 2].textContent.trim();
      customers.push({ pk: pk, company: company, contact: contact, postcode: postcode, status: status });
    });
    return customers;
  }

  function fetchAllPages() {
    setStatus('Scanning current page for OK customers...');
    return Promise.resolve(parseCustomersFromPage(document));
  }

  async function fetchCustomerDetail(pk) {
    var url = 'https://www.windowbase.info/prospect/customer?a=DISPLAY&sipm=&rr=0&pk=' + pk;
    var resp = await fetch(url, { credentials: 'include' });
    var text = await resp.text();
    var parser = new DOMParser();
    var doc = parser.parseFromString(text, 'text/html');

    var allText = doc.body.innerText || doc.body.textContent || '';
    var address1 = '', address2 = '', town = '', county = '', postcode = '', country = '', notes = '';
    var bodyLines = allText.split('\n').map(function(l) { return l.trim(); }).filter(Boolean);

    var pcIdx = bodyLines.findIndex(function(l) { return /^Postcode$/i.test(l); });
    if (pcIdx > 0) {
      var addrLines = bodyLines.slice(Math.max(0, pcIdx - 4), pcIdx);
      if (addrLines.length >= 1) address1 = addrLines[0] || '';
      if (addrLines.length >= 2) address2 = addrLines[1] || '';
      if (addrLines.length >= 3) town = addrLines[2] || '';
      if (addrLines.length >= 4) county = addrLines[3] || '';
    }

    var allBolds = [].slice.call(doc.querySelectorAll('b,strong'));
    allBolds.forEach(function(b) {
      var t = b.textContent.trim();
      if (/^[A-Z]{1,2}[0-9][0-9A-Z]?\s[0-9][A-Z]{2}$/i.test(t)) postcode = t;
    });

    var notesLabel = bodyLines.findIndex(function(l) { return /internal notes/i.test(l); });
    if (notesLabel >= 0 && bodyLines[notesLabel + 1] && !/field names/i.test(bodyLines[notesLabel + 1])) {
      notes = bodyLines[notesLabel + 1];
    }

    var countryLabel = bodyLines.findIndex(function(l) { return /^Country$/i.test(l); });
    if (countryLabel >= 0 && bodyLines[countryLabel + 1]) {
      var next = bodyLines[countryLabel + 1];
      if (!/email|website|internal/i.test(next)) country = next;
    }

    return { address1: address1, address2: address2, town: town, county: county, postcode: postcode, country: country, notes: notes };
  }

  async function fetchCustomerUsers(pk) {
    var url = 'https://www.windowbase.info/prospect/site_user?cid=' + pk + '&a=DISPLAY&m=0&resort=1';
    var resp = await fetch(url, { credentials: 'include' });
    var text = await resp.text();
    var parser = new DOMParser();
    var doc = parser.parseFromString(text, 'text/html');

    var users = [];
    var rows = doc.querySelectorAll('table tr');
    rows.forEach(function(row) {
      var cells = row.querySelectorAll('td');
      if (cells.length < 5) return;
      var name = cells[0].textContent.trim();
      var email = cells[1].textContent.trim();
      var lastLogin = cells[4].textContent.trim();
      if (!name || !email || name === 'Name') return;
      users.push({ name: name, email: email, lastLogin: lastLogin });
    });
    return users;
  }

  async function importToSupabase(customers) {
    var imported = 0;
    var errors = 0;
    for (var i = 0; i < customers.length; i++) {
      var c = customers[i];
      setStatus('Importing ' + (i + 1) + '/' + customers.length + ': ' + c.company + '...');
      setProgress((i / customers.length) * 100);
      try {
        var detail = await fetchCustomerDetail(c.pk);
        var users = await fetchCustomerUsers(c.pk);

        var custResp = await fetch(SUPABASE_URL + '/rest/v1/crm_customers', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'apikey': SUPABASE_KEY,
            'Authorization': 'Bearer ' + SUPABASE_KEY,
            'Prefer': 'return=representation'
          },
          body: JSON.stringify({
            company_name: c.company,
            status: 'active',
            address_line1: detail.address1,
            address_line2: detail.address2,
            town: detail.town,
            county: detail.county,
            postcode: detail.postcode || c.postcode,
            country: detail.country || 'UK',
            notes: detail.notes
          })
        });

        if (!custResp.ok) {
          var err = await custResp.text();
          console.error('Customer insert error:', err);
          errors++;
          continue;
        }

        var custData = await custResp.json();
        var custId = custData[0] && custData[0].id;

        if (custId && users.length > 0) {
          for (var j = 0; j < users.length; j++) {
            var u = users[j];
            var nameParts = u.name.split(' ');
            var firstName = nameParts[0] || '';
            var lastName = nameParts.slice(1).join(' ') || '';
            await fetch(SUPABASE_URL + '/rest/v1/crm_contacts', {
              method: 'POST',
              headers: {
                'Content-Type': 'application/json',
                'apikey': SUPABASE_KEY,
                'Authorization': 'Bearer ' + SUPABASE_KEY
              },
              body: JSON.stringify({
                customer_id: custId,
                first_name: firstName,
                last_name: lastName,
                email: u.email,
                is_primary: j === 0,
                notes: u.lastLogin ? 'Last login: ' + u.lastLogin : ''
              })
            });
          }
        }
        imported++;
      } catch (e) {
        console.error('Error importing', c.company, e);
        errors++;
      }
      await new Promise(function(r) { setTimeout(r, 300); });
    }
    setProgress(100);
    setStatus('Done! Imported ' + imported + ' customers.' + (errors > 0 ? ' ' + errors + ' errors (check console).' : ''));
  }

  fetchAllPages().then(function(customers) {
    if (!customers.length) {
      setStatus('No OK customers found on this page. Set Show to 200 and try again.');
      return;
    }

    var list = document.getElementById('crm-customer-list');
    list.innerHTML = '<div class="crm-count">' + customers.length + ' OK customers found</div>'
      + '<div class="crm-select-all-row">'
      + '<input type="checkbox" id="crm-select-all">'
      + '<label for="crm-select-all">Select all</label>'
      + '</div>'
      + customers.map(function(c) {
        return '<div class="crm-customer-item">'
          + '<input type="checkbox" id="crm-c-' + c.pk + '" data-pk="' + c.pk + '" class="crm-cb">'
          + '<label for="crm-c-' + c.pk + '"><strong>' + c.company + '</strong><br>' + c.contact + ' &middot; ' + c.postcode + '</label>'
          + '</div>';
      }).join('')
      + '<button class="crm-btn" id="crm-import-btn">Import Selected</button>'
      + '<button class="crm-btn cancel" id="crm-cancel-btn">Close</button>';

    setStatus(customers.length + ' OK customers found. Select and click Import.');

    document.getElementById('crm-select-all').addEventListener('change', function() {
      var checked = this.checked;
      document.querySelectorAll('.crm-cb').forEach(function(cb) { cb.checked = checked; });
    });

    document.getElementById('crm-cancel-btn').addEventListener('click', function() {
      overlay.remove();
    });

    document.getElementById('crm-import-btn').addEventListener('click', async function() {
      var selected = [].slice.call(document.querySelectorAll('.crm-cb:checked')).map(function(cb) {
        return customers.find(function(c) { return c.pk === cb.dataset.pk; });
      }).filter(Boolean);

      if (!selected.length) {
        setStatus('Please select at least one customer.');
        return;
      }

      document.getElementById('crm-import-btn').disabled = true;
      document.getElementById('crm-cancel-btn').disabled = true;
      await importToSupabase(selected);
      document.getElementById('crm-cancel-btn').disabled = false;
    });
  });
})();
