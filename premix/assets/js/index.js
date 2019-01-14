var premix = function() {
  function chunkSubstr(str, size) {
    const numChunks = Math.ceil(str.length / size)
    const chunks = new Array(numChunks)

    for (let i = 0, o = 0; i < numChunks; ++i, o += size) {
      chunks[i] = str.substr(o, size)
    }

    return chunks
  }

  function split32(text) {
    if(text.length > 32) {
      let chunks = chunkSubstr(text, 32);
      let result = "";
      for(var x of chunks) {
        result += '<div>'+x+'</div>';
      }
      return result;
    } else {
      return text;
    }
  }

  return {
    fields: ['op', 'pc', 'gas', 'gasCost', 'depth'],

    newTable: function(container) {
      let table = $('<table class="uk-table uk-table-divider"/>').appendTo(container);
      $('<thead><tr><th>Field</th><th>Nimbus</th><th>Geth</th></tr></thead>').appendTo(table);
      return $('<tbody></tbody>').appendTo(table);
    },

    renderRow: function(body, nimbus, geth, x) {
      let row = $('<tr/>').appendTo(body);
      let ncr = nimbus instanceof Object ? nimbus[x].toString().toLowerCase() : nimbus;
      let gcr = geth instanceof Object ? geth[x].toString().toLowerCase() : geth;
      let cls = ncr == gcr ? '' : 'class="uk-text-danger"';
      $(`<td ${cls}>${split32(x)}</td>`).appendTo(row);
      $(`<td ${cls}>${split32(ncr)}</td>`).appendTo(row);
      $(`<td ${cls}>${split32(gcr)}</td>`).appendTo(row);
    },

    newSection: function(container, title, colored) {
      let section = $('<div class="uk-section uk-section-xsmall tm-horizontal-overflow"></div>').appendTo(container);
      section.addClass(colored ? "uk-section-secondary uk-light" : "uk-section-muted");
      let contentDiv = $('<div class="uk-container uk-margin-small-left uk-margin-small-right"></div>').appendTo(section);
      $(`<h4>${title}</h4>`).appendTo(contentDiv);
      return contentDiv;
    }

  };
}();

function windowResize() {
  let bodyHeight = $(window).height();
  $('#opCodeSideBar').css('height', parseInt(bodyHeight) - 80);
}

function renderTrace(title, nimbus, geth) {
  let container = $('#opCodeContainer').empty();
  let body = premix.newTable(container);
  for(var x of premix.fields) {
    premix.renderRow(body, nimbus, geth, x);
  }

  if(nimbus.error) {
    geth.error = '';
    premix.renderRow(body, nimbus, geth, 'error');
  }

  function renderExtra(name) {
    let nk = Object.keys(nimbus[name]);
    let gk = Object.keys(geth[name]);
    let keys = new Set(nk.concat(gk));

    if(keys.size > 0) {
      let section = premix.newSection(container, name);
      let body = premix.newTable(section);
      for(var key of keys) {
        premix.renderRow(body, nimbus[name], geth[name], key);
      }
      $('<hr class="uk-divider-icon">').appendTo(container);
    }
  }

  renderExtra("memory");
  renderExtra("stack");
  renderExtra("storage");
}

function opCodeRenderer(txId, nimbus, geth) {
  function analyzeList(nimbus, geth) {
    for(var i in nimbus) {
      if(nimbus[i].toString().toLowerCase() != geth[i].toString().toLowerCase()) return false;
    }
    return true;
  }

  function analyze(nimbus, geth) {
    for(var x of premix.fields) {
      if(nimbus[x] === undefined) nimbus[x] = '';
      if(geth[x] === undefined) geth[x] = '';
      if(nimbus[x].toString().toLowerCase() != geth[x].toString().toLowerCase()) return false;
    }

    let result = analyzeList(nimbus.memory, geth.memory);
    result = result && analyzeList(nimbus.stack, geth.stack);
    result = result && analyzeList(nimbus.storage, geth.storage);
    return result;
  }

  txId = parseInt(txId);
  var ncs = nimbus.txTraces[txId].structLogs;
  var gcs = geth.txTraces[txId].structLogs;
  var sideBar = $('#opCodeSideBar').empty();
  $('#opCodeTitle').text(`Tx #${(txId+1)}`);

  function fillEmptyOp(a, b) {
    const emptyOp = {op: '', pc: '', gas: '', gasCost: '', depth: '',
      storage:{}, memory: [], stack: []};

    if(a.length > b.length) {
      for(var i in a) {
        if(b[i] === undefined) {
          b[i] = emptyOp;
        }
      }
    }
  }

  fillEmptyOp(ncs, gcs);
  fillEmptyOp(gcs, ncs);

  for(var i in ncs) {
    var pc = ncs[i];
    if(!analyze(ncs[i], gcs[i])) {
      var nav = $(`<li><a class="tm-text-danger" rel="${i}" href="#">${pc.pc + ' ' + pc.op}</a></li>`).appendTo(sideBar);
    } else {
      var nav = $(`<li><a rel="${i}" href="#">${pc.pc + ' ' + pc.op}</a></li>`).appendTo(sideBar);
    }
    nav.children('a').click(function(ev) {
      let idx = this.rel;
      $('#opCodeSideBar li').removeClass('uk-active');
      $(this).parent().addClass('uk-active');
      renderTrace('tx', ncs[idx], gcs[idx]);
    });
  }

  if(ncs.length > 0) {
    renderTrace("tx", ncs[0], gcs[0]);
  }

  windowResize();
}

function transactionsRenderer(txId, nimbus, geth) {
  txId = parseInt(txId);
  $('#transactionsTitle').text(`Tx #${(txId+1)}`);
  let container = $('#transactionsContainer').empty();

  function renderTx(nimbus, geth) {
    let body = premix.newTable(container);
    const fields = ["gas", "returnValue", "cumulativeGasUsed", "bloom"];
    for(var x of fields) {
      premix.renderRow(body, nimbus, geth, x);
    }
    $('<hr class="uk-divider-icon">').appendTo(container);

    if(nimbus.root || geth.root) {
      if(geth.root === undefined) geth.root = '';
      if(nimbus.root == undefined) nimbus.root = '';
      premix.renderRow(body, nimbus, geth, 'root');
    }

    if(nimbus.status || geth.status) {
      if(geth.status === undefined) geth.status = '';
      if(nimbus.status == undefined) nimbus.status = '';
      premix.renderRow(body, nimbus, geth, 'status');
    }

    function fillEmptyLogs(a, b) {
      const emptyLog = {address: '', topics: [], data: ''};

      if(a.logs.length > b.logs.length) {
        for(var i in a.logs) {
          if(b.logs[i] === undefined) {
            b.logs[i] = emptyLog;
          }
        }
      }
    }

    fillEmptyLogs(geth, nimbus);
    fillEmptyLogs(nimbus, geth);

    for(var i in nimbus.logs) {
      $(`<h4>Receipt Log #${i}</h4>`).appendTo(container);
      let a = nimbus.logs[i];
      let b = geth.logs[i];
      a.topics = a.topics.join(',');
      b.topics = b.topics.join(',');
      let body = premix.newTable(container);
      premix.renderRow(body, a, b, 'address');
      premix.renderRow(body, a, b, 'data');
      premix.renderRow(body, a, b, 'topics');
      $('<hr class="uk-divider-icon">').appendTo(container);
    }
  }

  txId = parseInt(txId);
  let ntx = nimbus.txTraces[txId];
  let gtx = geth.txTraces[txId];

  if(ntx.returnValue.length == 0) {
    ntx.returnValue = "0x";
  }

  let ncr = $.extend({
    gas: ntx.gas,
    returnValue: ntx.returnValue
  },
    nimbus.receipts[txId]
  );

  let gcr = $.extend({
    gas: gtx.gas,
    returnValue: "0x" + gtx.returnValue
  },
    geth.receipts[txId]
  );

  renderTx(ncr, gcr);
}

function headerRenderer(nimbus, geth) {
  function emptyAccount() {
    return {
      address: '',
      nonce: '',
      balance: '',
      codeHash: '',
      code: '',
      storageRoot: '',
      storage: {}
    };
  }

  function deepCopy(src) {
    return JSON.parse(JSON.stringify(src));
  }

  let container = $('#headerContainer').empty();
  $('#headerTitle').text('Block #' + parseInt(geth.block.number, 16));

  let ncs = deepCopy(nimbus.stateDump.after);
  let gcs = deepCopy(geth.accounts);
  let accounts = [];

  for(var address in ncs) {
    let n = ncs[address];
    n.address = address;
    if(gcs[address]) {
      let geth = gcs[address];
      geth.address = address;
      accounts.push({name: n.name, nimbus: n, geth: geth});
      delete gcs[address];
    } else {
      accounts.push({name: n.name, nimbus: n, geth: emptyAccount()});
    }
  }

  for(var address in gcs) {
    let geth = gcs[address];
    geth.address = address;
    accounts.push({name: "unknown", nimbus: emptyAccount(), geth: geth});
  }

  for(var acc of accounts) {
    $(`<h4>Account Name: ${acc.name}</h4>`).appendTo(container);
    let body = premix.newTable(container);
    const fields = ['address', 'nonce', 'balance', 'codeHash', 'code', 'storageRoot'];
    for(var x of fields) {
      premix.renderRow(body, acc.nimbus, acc.geth, x);
    }

    let storage = [];
    let nss = acc.nimbus.storage;
    let gss = acc.geth.storage;

    for(var idx in nss) {
      if(gss[idx]) {
        storage.push({idx: idx, nimbus: nss[idx], geth: gss[idx]});
        delete gss[idx];
      } else {
        if(nss[idx] != "0x0000000000000000000000000000000000000000000000000000000000000000") {
          storage.push({idx: idx, nimbus: nss[idx], geth: ''});
        }
      }
    }
    for(var idx in gss) {
      if(gss[idx] != "0x0000000000000000000000000000000000000000000000000000000000000000") {
        storage.push({idx: idx, nimbus: '', geth: gss[idx]});
      }
    }

    if(storage.length > 0) {
      $(`<h4>${acc.name} Storage</h4>`).appendTo(container);
      let body = premix.newTable(container);
      for(var s of storage) {
        premix.renderRow(body, s.nimbus, s.geth, s.idx);
      }
    }

    $('<hr class="uk-divider-icon">').appendTo(container);
  }
}

function generateNavigation(txs, nimbus, geth) {
  function navAux(menuId, renderer) {
    let menu = $(menuId).click(function(ev) {
      renderer(0, nimbus, geth);
    });

    if(txs.length == 0) {
      menu.parent().addClass('uk-disabled');
    } else if(txs.length > 1) {
      $('<span uk-icon="icon: triangle-down"></span>').appendTo(menu);
      let div  = $('<div uk-dropdown="mode: hover;"/>').appendTo(menu.parent());
      let list = $('<ul class="uk-nav uk-dropdown-nav"/>').appendTo(div);

      for(var i in txs) {
        let id = parseInt(i) + 1;
        $(`<li class="uk-active"><a rel="${i}" href="#">TX #${id}</a></li>`).appendTo(list);
      }

      list.find('li a').click(function(ev) {
        renderer(this.rel, nimbus, geth);
      });
    }
  }

  navAux('#opCodeMenu', opCodeRenderer);
  navAux('#transactionsMenu', transactionsRenderer);

  $('#headerMenu').click(function(ev) {
    headerRenderer(nimbus, geth);
  });
}

$(document).ready(function() {

  var nimbus = premixData.nimbus;
  var geth = premixData.geth;
  var transactions = geth.block.transactions;

  generateNavigation(transactions, nimbus, geth);
});