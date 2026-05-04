// apps-script/Code.gs
// Deploy as Web App: Execute as Me, Who has access: Anyone.
// GET  ?id=<sessionId>                        → { ok: true, data: {...} } or { ok: false, error: "not found" }
// GET  ?action=list                           → { ok: true, data: [SessionMeta] }
// GET  ?action=players                        → { ok: true, data: [PlayerSummary] }
// GET  ?action=playerStats&name=<name>        → { ok: true, data: PlayerStats }
// POST body (text/plain JSON str)             → { ok: true } or { ok: false, error: "..." }

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
  var action = e.parameter.action;

  if (action === 'list') return handleList();
  if (action === 'players') return handlePlayers();
  if (action === 'playerStats') return handlePlayerStats(e.parameter.name);

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

function handleList() {
  var sheet = getSheet();
  var values = sheet.getDataRange().getValues();
  var sessions = [];
  for (var i = 1; i < values.length; i++) {
    try {
      var data = JSON.parse(values[i][3]);
      sessions.push({
        id: values[i][0],
        title: data.session.title || '',
        date: data.session.date || '',
        playerCount: data.players ? data.players.length : 0,
        totalGames: data.session.totalGames || 0,
      });
    } catch (err) { console.error('Row ' + i + ':', err.message); }
  }
  sessions.sort(function(a, b) { return b.date.localeCompare(a.date); });
  return respond({ ok: true, data: sessions });
}

function handlePlayers() {
  var sheet = getSheet();
  var values = sheet.getDataRange().getValues();
  var playerMap = {};
  var playerDates = {};

  for (var i = 1; i < values.length; i++) {
    try {
      var data = JSON.parse(values[i][3]);
      var sessionDate = data.session.date || '';
      var players = data.players || [];
      for (var j = 0; j < players.length; j++) {
        var p = players[j];
        var key = p.name.toLowerCase();
        if (!playerMap[key] || sessionDate > playerDates[key]) {
          playerMap[key] = { name: p.name, gender: p.gender, tier: p.tier };
          playerDates[key] = sessionDate;
        }
      }
    } catch (err) { console.error('Row ' + i + ':', err.message); }
  }

  var result = Object.keys(playerMap).map(function(k) { return playerMap[k]; });
  result.sort(function(a, b) { return a.name.toLowerCase().localeCompare(b.name.toLowerCase()); });
  return respond({ ok: true, data: result });
}

function handlePlayerStats(name) {
  if (!name) return respond({ ok: false, error: 'missing name' });
  var nameLower = name.toLowerCase();

  var sheet = getSheet();
  var values = sheet.getDataRange().getValues();

  var gamesPlayed = 0, wins = 0, losses = 0, pointsFor = 0, pointsAgainst = 0;
  var sessionsMap = {};
  var partnerMap = {};
  var opponentMap = {};
  var resolvedName = name;

  for (var i = 1; i < values.length; i++) {
    try {
      var data = JSON.parse(values[i][3]);
      var sessionId = values[i][0];
      var sessionDate = data.session.date || '';
      var sessionTitle = data.session.title || '';
      var players = data.players || [];
      var schedule = data.schedule || [];
      var gameScores = data.gameScores || {};

      var playerInSession = null;
      for (var j = 0; j < players.length; j++) {
        if (players[j].name.toLowerCase() === nameLower) {
          playerInSession = players[j];
          resolvedName = players[j].name;
          break;
        }
      }
      if (!playerInSession) continue;

      var playerId = playerInSession.id;
      var sessionAdded = false;

      for (var k = 0; k < schedule.length; k++) {
        var slot = schedule[k];
        var teamA = slot.teamA || [];
        var teamB = slot.teamB || [];
        var inA = teamA.indexOf(playerId) !== -1;
        var inB = teamB.indexOf(playerId) !== -1;
        if (!inA && !inB) continue;

        gamesPlayed++;
        if (!sessionAdded) {
          sessionsMap[sessionId] = { id: sessionId, date: sessionDate, title: sessionTitle };
          sessionAdded = true;
        }

        var scoreKey = slot.slot + '-' + slot.court;
        var score = gameScores[scoreKey];
        var gameWon = null;
        if (score) {
          var myScore = inA ? score.a : score.b;
          var oppScore = inA ? score.b : score.a;
          pointsFor += myScore;
          pointsAgainst += oppScore;
          if (myScore > oppScore) { wins++; gameWon = true; }
          else { losses++; gameWon = false; }
        }

        var myTeam = inA ? teamA : teamB;
        var oppTeam = inA ? teamB : teamA;

        for (var m = 0; m < myTeam.length; m++) {
          if (myTeam[m] === playerId) continue;
          var partner = findPlayerById(players, myTeam[m]);
          if (partner) {
            var pk = partner.name.toLowerCase();
            if (!partnerMap[pk]) partnerMap[pk] = { name: partner.name, count: 0, wins: 0, losses: 0 };
            partnerMap[pk].count++;
            if (gameWon === true) partnerMap[pk].wins++;
            else if (gameWon === false) partnerMap[pk].losses++;
          }
        }

        for (var n = 0; n < oppTeam.length; n++) {
          var opp = findPlayerById(players, oppTeam[n]);
          if (opp) {
            var oppKey = opp.name.toLowerCase();
            if (!opponentMap[oppKey]) opponentMap[oppKey] = { name: opp.name, count: 0, wins: 0, losses: 0 };
            opponentMap[oppKey].count++;
            if (gameWon === true) opponentMap[oppKey].wins++;
            else if (gameWon === false) opponentMap[oppKey].losses++;
          }
        }
      }
    } catch (err) { console.error('Row ' + i + ':', err.message); }
  }

  var topPartners = Object.keys(partnerMap).map(function(k) {
    return { name: partnerMap[k].name, count: partnerMap[k].count, wins: partnerMap[k].wins, losses: partnerMap[k].losses };
  }).sort(function(a, b) { return b.count - a.count; }).slice(0, 5);

  var topOpponents = Object.keys(opponentMap).map(function(k) {
    return { name: opponentMap[k].name, count: opponentMap[k].count, wins: opponentMap[k].wins, losses: opponentMap[k].losses };
  }).sort(function(a, b) { return b.count - a.count; }).slice(0, 5);

  var sessionsList = Object.keys(sessionsMap).map(function(k) { return sessionsMap[k]; });
  sessionsList.sort(function(a, b) { return b.date.localeCompare(a.date); });

  return respond({
    ok: true,
    data: {
      name: resolvedName,
      gamesPlayed: gamesPlayed,
      wins: wins,
      losses: losses,
      pointsFor: pointsFor,
      pointsAgainst: pointsAgainst,
      sessions: sessionsList,
      topPartners: topPartners,
      topOpponents: topOpponents,
    }
  });
}

function findPlayerById(players, id) {
  for (var i = 0; i < players.length; i++) {
    if (players[i].id === id) return players[i];
  }
  return null;
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
