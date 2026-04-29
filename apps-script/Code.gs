// apps-script/Code.gs
// Deploy as Web App: Execute as Me, Who has access: Anyone.
// GET  ?id=<sessionId>            → { ok: true, data: {...} } or { ok: false, error: "not found" }
// POST body (text/plain JSON str) → { ok: true } or { ok: false, error: "..." }

var SHEET_NAME = 'Sessions';

function getSheet() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName(SHEET_NAME);
  if (!sheet) {
    sheet = ss.insertSheet(SHEET_NAME);
    sheet.appendRow(['session_id', 'created_at', 'updated_at', 'data']);
  }
  return sheet;
}

function doGet(e) {
  var id = e.parameter.id;
  if (!id) return respond({ ok: false, error: 'missing id' });

  var sheet = getSheet();
  var values = sheet.getDataRange().getValues();

  for (var i = 1; i < values.length; i++) {
    if (values[i][0] === id) {
      var data = JSON.parse(values[i][3]);
      return respond({ ok: true, data: data });
    }
  }

  return respond({ ok: false, error: 'not found' });
}

function doPost(e) {
  var payload;
  try {
    payload = JSON.parse(e.postData.contents);
  } catch (err) {
    return respond({ ok: false, error: 'invalid JSON' });
  }

  var id = payload.id;
  var data = payload.data;
  if (!id || !data) return respond({ ok: false, error: 'missing id or data' });

  var sheet = getSheet();
  var values = sheet.getDataRange().getValues();
  var now = new Date().toISOString();

  for (var i = 1; i < values.length; i++) {
    if (values[i][0] === id) {
      sheet.getRange(i + 1, 3).setValue(now);
      sheet.getRange(i + 1, 4).setValue(JSON.stringify(data));
      return respond({ ok: true });
    }
  }

  sheet.appendRow([id, now, now, JSON.stringify(data)]);
  return respond({ ok: true });
}

function respond(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
